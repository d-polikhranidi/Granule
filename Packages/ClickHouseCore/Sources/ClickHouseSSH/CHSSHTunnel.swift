import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// A server reached through an SSH bastion: a port on this device
/// (127.0.0.1) whose connections the bastion forwards to the server
/// (direct-tcpip channels). The bastion's host key is checked against the
/// one seen before (kept by the caller), or taken the first time.
public final class CHSSHTunnel: @unchecked Sendable {
    public struct Settings: Sendable, Hashable {
        public var host: String
        public var port: Int
        public var user: String
        public var password: String?
        /// The private key's text (OpenSSH or PEM).
        public var privateKey: String?
        /// The bastion's host key as OpenSSH writes it (`ssh-ed25519 AAAA…`); `nil` the first time.
        public var knownHostKey: String?

        public init(host: String, port: Int = 22, user: String, password: String? = nil, privateKey: String? = nil, knownHostKey: String? = nil) {
            self.host = host
            self.port = port
            self.user = user
            self.password = password
            self.privateKey = privateKey
            self.knownHostKey = knownHostKey
        }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case authenticationFailed
        /// The bastion's key isn't the one seen before (another server, or one pretending).
        case hostKeyChanged(expected: String, presented: String)
        /// No connection to the bastion (`host:port`).
        case unreachable(String)
        /// The SSH connection failed while signing in, for another reason (said as it is).
        case failed(String)
        case closed

        public var description: String {
            switch self {
            case .authenticationFailed: String(localized: "The SSH server didn't accept the user, password or key.", bundle: .module)
            case .hostKeyChanged(_, let presented):
                String(localized: "The SSH server's key has changed (now \(presented.prefix(40))…): it may be another server. Check it, then forget the old key in the connection's settings.", bundle: .module)
            case .unreachable(let address): String(localized: "The SSH server \(address) can't be reached.", bundle: .module)
            case .failed(let reason): String(localized: "The SSH connection failed: \(reason)", bundle: .module)
            case .closed: String(localized: "The SSH connection closed.", bundle: .module)
            }
        }
    }

    /// The local port the server is reached on (the same for the tunnel's life).
    public private(set) var localPort = 0
    /// The bastion's host key as presented (to keep for the next time).
    public let hostKey: String

    private let settings: Settings
    private let key: NIOSSHPrivateKey?
    private let group: MultiThreadedEventLoopGroup
    /// The one thread every channel of the tunnel is on: the state below is only touched there.
    private let loop: EventLoop
    private var _sshChannel: Channel
    private var sshChannel: Channel {
        get { lock.withLock { _sshChannel } }
        set { lock.withLock { _sshChannel = newValue } }
    }
    /// Signing in again, after the SSH connection dropped.
    private var reconnecting: EventLoopFuture<Channel>?
    /// How many times it signed in again (tests).
    private(set) var reconnectsForTesting = 0
    private var listener: Channel?
    private let lock = NSLock()
    private var closed = false

    private init(settings: Settings, key: NIOSSHPrivateKey?, hostKey: String, group: MultiThreadedEventLoopGroup, loop: EventLoop, sshChannel: Channel) {
        var settings = settings
        settings.knownHostKey = hostKey
        self.settings = settings
        self.key = key
        self.hostKey = hostKey
        self.group = group
        self.loop = loop
        _sshChannel = sshChannel
    }

    deinit { close() }

    /// Connects to the bastion, signs in, and opens a local port forwarded to `target:targetPort`.
    /// When the SSH connection drops (the Mac slept, the bastion closed it), the next
    /// connection to the port signs in again first, with the host key seen the first time.
    public static func open(_ settings: Settings, target: String, targetPort: Int) async throws -> CHSSHTunnel {
        let key = try settings.privateKey.map(CHSSHKey.parse)
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let loop = group.next()
        do {
            let (channel, hostKey) = try await signIn(settings, key: key, on: loop).get()
            let tunnel = CHSSHTunnel(settings: settings, key: key, hostKey: hostKey, group: group, loop: loop, sshChannel: channel)
            try await tunnel.listen(on: 0, target: target, targetPort: targetPort).get()
            return tunnel
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    /// The local port, and the same port again if the system takes it away
    /// (iOS may close the listening sockets of a suspended app).
    private func listen(on port: Int, target: String, targetPort: Int, attempts: Int = 5) -> EventLoopFuture<Void> {
        ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { [weak self] inbound in
                guard let self else { return inbound.close() }
                return forward(inbound, to: target, port: targetPort)
            }
            .bind(host: "127.0.0.1", port: port)
            .flatMapThrowing { [weak self] listener in
                guard let self, let bound = listener.localAddress?.port else {
                    listener.close(promise: nil)
                    throw Failure.closed
                }
                lock.withLock { self.listener = listener }
                localPort = bound
                listener.closeFuture.whenComplete { [weak self] _ in
                    guard let self, !lock.withLock({ closed }) else { return }
                    reopen(bound, target: target, targetPort: targetPort, attempts: attempts)
                }
            }
    }

    private func reopen(_ port: Int, target: String, targetPort: Int, attempts: Int) {
        guard attempts > 0 else { return }
        loop.scheduleTask(in: .milliseconds(200)) { [weak self] in
            guard let self, !lock.withLock({ closed }) else { return }
            listen(on: port, target: target, targetPort: targetPort).whenFailure { [weak self] _ in
                self?.reopen(port, target: target, targetPort: targetPort, attempts: attempts - 1)
            }
        }
    }

    /// An SSH connection signed in, and the host key the bastion presented.
    private static func signIn(_ settings: Settings, key: NIOSSHPrivateKey?, on loop: EventLoop) -> EventLoopFuture<(Channel, String)> {
        let hostKeys = HostKeyCheck(known: settings.knownHostKey)
        let signedIn = loop.makePromise(of: Void.self)
        let authentication = Authentication(user: settings.user, password: settings.password, key: key)
        let connected = ClientBootstrap(group: loop)
            .connectTimeout(.seconds(20))
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    let handler = NIOSSHHandler(role: .client(.init(userAuthDelegate: authentication, serverAuthDelegate: hostKeys)),
                                                allocator: channel.allocator, inboundChildChannelInitializer: nil)
                    try channel.pipeline.syncOperations.addHandler(handler)
                    try channel.pipeline.syncOperations.addHandler(SignInWatcher(promise: signedIn, hostKeys: hostKeys))
                }
            }
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .connect(host: settings.host, port: settings.port)
            .flatMapErrorThrowing { _ in
                let failure = hostKeys.failure ?? Failure.unreachable("\(settings.host):\(settings.port)")
                signedIn.fail(failure)
                throw failure
            }
        return connected.flatMap { channel in
            // A bastion that never answers the sign-in.
            let timeout = loop.scheduleTask(in: .seconds(30)) {
                signedIn.fail(Failure.authenticationFailed)
                channel.close(promise: nil)
            }
            return signedIn.futureResult.map {
                timeout.cancel()
                return (channel, hostKeys.presented ?? "")
            }.flatMapErrorThrowing { error in
                timeout.cancel()
                channel.close(promise: nil)
                if let failure = hostKeys.failure ?? (error as? Failure) { throw failure }
                throw Failure.failed(String(describing: error))
            }
        }
    }

    /// The SSH connection: the one open, or a new one when it dropped.
    private func connection() -> EventLoopFuture<Channel> {
        loop.preconditionInEventLoop()
        if sshChannel.isActive { return loop.makeSucceededFuture(sshChannel) }
        if let reconnecting { return reconnecting }
        reconnectsForTesting += 1
        let future = Self.signIn(settings, key: key, on: loop).map { [weak self] channel, _ in
            self?.sshChannel = channel
            self?.reconnecting = nil
            return channel
        }
        future.whenFailure { [weak self] _ in self?.reconnecting = nil }
        reconnecting = future
        return future
    }

    /// A local connection glued to a new direct-tcpip channel of the SSH connection.
    private func forward(_ inbound: Channel, to target: String, port: Int) -> EventLoopFuture<Void> {
        connection().flatMap { sshChannel in
            let promise = inbound.eventLoop.makePromise(of: Channel.self)
            let originator = inbound.remoteAddress ?? (try! SocketAddress(ipAddress: "127.0.0.1", port: 0))
            do {
                let ssh = try sshChannel.pipeline.syncOperations.handler(type: NIOSSHHandler.self)
                ssh.createChannel(promise, channelType: .directTCPIP(.init(targetHost: target, targetPort: port, originatorAddress: originator))) { child, _ in
                    child.eventLoop.makeCompletedFuture {
                        let (ours, theirs) = Glue.pair()
                        try child.pipeline.syncOperations.addHandler(DataWrapper())
                        try child.pipeline.syncOperations.addHandler(ours)
                        try inbound.pipeline.syncOperations.addHandler(theirs)
                    }
                }
            } catch {
                promise.fail(error)
            }
            return promise.futureResult.map { _ in }
        }
    }

    public func close() {
        let first = lock.withLock { defer { closed = true }; return !closed }
        guard first else { return }
        lock.withLock { listener }?.close(promise: nil)
        sshChannel.close(promise: nil)
        group.shutdownGracefully { _ in }
    }

    /// Closes the local port as the system would: it opens again on the same port.
    func closeListenerForTesting() async throws {
        try await lock.withLock { listener }?.close()
    }

    /// Drops the SSH connection (the local port stays): what sleep or the bastion does.
    func dropConnectionForTesting() async throws {
        try await loop.submit { self.sshChannel }.get().close()
    }
}

// MARK: Handlers

/// Offers the key, then the password, as the bastion takes them.
private final class Authentication: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let user: String
    let password: String?
    let key: NIOSSHPrivateKey?
    private var triedKey = false, triedPassword = false

    init(user: String, password: String?, key: NIOSSHPrivateKey?) {
        self.user = user
        self.password = password
        self.key = key
    }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        if let key, !triedKey, availableMethods.contains(.publicKey) {
            triedKey = true
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: user, serviceName: "", offer: .privateKey(.init(privateKey: key))))
        } else if let password, !triedPassword, availableMethods.contains(.password) {
            triedPassword = true
            nextChallengePromise.succeed(NIOSSHUserAuthenticationOffer(username: user, serviceName: "", offer: .password(.init(password: password))))
        } else {
            // Not nil: NIOSSH would then wait with the connection open. A failure closes it.
            nextChallengePromise.fail(CHSSHTunnel.Failure.authenticationFailed)
        }
    }
}

/// The bastion's host key: the one known, or taken the first time.
private final class HostKeyCheck: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let known: String?
    private(set) var presented: String?
    private(set) var failure: CHSSHTunnel.Failure?

    init(known: String?) { self.known = known }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let text = String(openSSHPublicKey: hostKey)
        presented = text
        if let known, Self.keyPart(known) != Self.keyPart(text) {
            let failure = CHSSHTunnel.Failure.hostKeyChanged(expected: known, presented: text)
            self.failure = failure
            validationCompletePromise.fail(failure)
        } else {
            validationCompletePromise.succeed(())
        }
    }

    /// The type and key, without a comment.
    private static func keyPart(_ text: String) -> String {
        text.split(separator: " ").prefix(2).joined(separator: " ")
    }
}

/// Tells when signing in succeeded, or that the connection closed before.
private final class SignInWatcher: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any
    private let promise: EventLoopPromise<Void>
    private let hostKeys: HostKeyCheck
    private var done = false

    init(promise: EventLoopPromise<Void>, hostKeys: HostKeyCheck) {
        self.promise = promise
        self.hostKeys = hostKeys
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent, !done {
            done = true
            promise.succeed(())
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        finish(hostKeys.failure ?? error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        finish(hostKeys.failure ?? CHSSHTunnel.Failure.authenticationFailed)
        context.fireChannelInactive()
    }

    private func finish(_ error: Error) {
        guard !done else { return }
        done = true
        promise.fail(error)
    }
}

/// SSH channel data to bytes and back.
private final class DataWrapper: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)
        guard case .channel = data.type, case .byteBuffer(let buffer) = data.data else { return }
        context.fireChannelRead(wrapInboundOut(buffer))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        context.write(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(unwrapOutboundIn(data)))), promise: promise)
    }
}

/// Two channels glued: what one reads the other writes, with back pressure (NIO's example's).
private final class Glue: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: Glue?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    static func pair() -> (Glue, Glue) {
        let first = Glue(), second = Glue()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) { partner?.context?.write(data, promise: nil) }
    func channelReadComplete(context: ChannelHandlerContext) { partner?.context?.flush() }
    func channelInactive(context: ChannelHandlerContext) { partner?.context?.close(promise: nil) }
    func errorCaught(context: ChannelHandlerContext, error: Error) { partner?.context?.close(promise: nil) }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event { partner?.context?.close(mode: .output, promise: nil) }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    func read(context: ChannelHandlerContext) {
        if let partner, partner.context?.channel.isWritable ?? false { context.read() } else { pendingRead = true }
    }

    private func partnerBecameWritable() {
        guard pendingRead else { return }
        pendingRead = false
        context?.read()
    }
}
