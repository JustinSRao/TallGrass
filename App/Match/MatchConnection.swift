import Foundation
import MultipeerConnectivity
import Observation
import TallGrassKit
import UIKit

/// Everything two phones say to each other during a match. Only small
/// facts travel: seeds, teams and battle choices. Each phone computes the
/// rest itself, deterministically.
enum MatchMessage: Codable, Equatable {
    case hello(name: String, protocolVersion: Int, packName: String, packSpecies: Int)
    case startHunt(seed: UInt64, config: HuntConfig, startAt: Date)
    case progress(caught: Int)
    case team([BattleMon])
    case startBattle(seed: [UInt16])
    case choice(round: Int, side: String, choice: String)
    case rematch
    case leave
}

/// A peer-to-peer link to one friend nearby (Wi-Fi/Bluetooth, no internet or
/// server). One phone hosts (advertises), the other joins (browses).
@MainActor @Observable
final class MatchConnection: NSObject {
    enum Role { case host, guest }
    enum State: Equatable {
        case idle
        case searching
        case connecting(String)
        case connected(String)
        case failed(String)
    }

    static let serviceType = "tallgrass"   // must match NSBonjourServices in Info.plist
    static let protocolVersion = 1

    private(set) var state: State = .idle
    private(set) var nearbyHosts: [MCPeerID] = []
    private(set) var peerName: String?
    var role: Role = .host

    /// Called on the main actor for every message from the friend.
    var onMessage: (@MainActor (MatchMessage) -> Void)?

    private let me = MCPeerID(displayName: UIDevice.current.name)
    private var session: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    func host() {
        stop()
        role = .host
        let session = makeSession()
        let advertiser = MCNearbyServiceAdvertiser(peer: me, discoveryInfo: nil, serviceType: Self.serviceType)
        advertiser.delegate = self
        advertiser.startAdvertisingPeer()
        self.session = session
        self.advertiser = advertiser
        state = .searching
    }

    func join() {
        stop()
        role = .guest
        let session = makeSession()
        let browser = MCNearbyServiceBrowser(peer: me, serviceType: Self.serviceType)
        browser.delegate = self
        browser.startBrowsingForPeers()
        self.session = session
        self.browser = browser
        nearbyHosts = []
        state = .searching
    }

    func invite(_ peer: MCPeerID) {
        guard let session, let browser else { return }
        browser.invitePeer(peer, to: session, withContext: nil, timeout: 20)
        state = .connecting(peer.displayName)
    }

    func send(_ message: MatchMessage) {
        guard let session, !session.connectedPeers.isEmpty,
              let data = try? JSONEncoder().encode(message) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session?.disconnect()
        advertiser = nil
        browser = nil
        session = nil
        nearbyHosts = []
        peerName = nil
        state = .idle
    }

    private func makeSession() -> MCSession {
        let session = MCSession(peer: me, securityIdentity: nil, encryptionPreference: .required)
        session.delegate = self
        return session
    }

    // MARK: Main-actor handlers for delegate callbacks

    fileprivate func peerChanged(_ peer: MCPeerID, _ newState: MCSessionState) {
        switch newState {
        case .connected:
            peerName = peer.displayName
            state = .connected(peer.displayName)
            // One friend is enough: stop being discoverable.
            advertiser?.stopAdvertisingPeer()
            browser?.stopBrowsingForPeers()
        case .connecting:
            state = .connecting(peer.displayName)
        case .notConnected:
            if peerName == peer.displayName || isConnected {
                state = .failed("\(peer.displayName) disconnected")
            } else if case .connecting = state {
                state = .searching
            }
        @unknown default:
            break
        }
    }

    fileprivate func received(_ data: Data) {
        guard let message = try? JSONDecoder().decode(MatchMessage.self, from: data) else { return }
        onMessage?(message)
    }

    fileprivate func found(_ peer: MCPeerID) {
        if !nearbyHosts.contains(peer) { nearbyHosts.append(peer) }
    }

    fileprivate func lost(_ peer: MCPeerID) {
        nearbyHosts.removeAll { $0 == peer }
    }

    fileprivate func acceptInvitation(_ handler: @escaping (Bool, MCSession?) -> Void) {
        // Host accepts the first friend who asks.
        handler(!isConnected, isConnected ? nil : session)
    }
}

extension MatchConnection: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor in self.peerChanged(peerID, state) }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor in self.received(data) }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

extension MatchConnection: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                                withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor in self.acceptInvitation(invitationHandler) }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor in self.state = .failed("Couldn't start hosting: \(error.localizedDescription)") }
    }
}

extension MatchConnection: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor in self.found(peerID) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor in self.lost(peerID) }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor in self.state = .failed("Couldn't search for friends: \(error.localizedDescription)") }
    }
}
