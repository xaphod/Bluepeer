//
//  HotPotatoNetwork.swift
//
//  Created by Tim Carr on 2017-03-07.
//  Copyright © 2017 Tim Carr. All rights reserved.

import Foundation
import xaphodObjCUtils
import ObjectMapper

public protocol HandlesHotPotatoMessages {
    var isActiveAsHandler: Bool { get }
    func handleHotPotatoMessage(message: HotPotatoMessage, peer: BPPeer, HPN: HotPotatoNetwork)
}

public protocol HandlesPotato {
    func youStartThePotato() -> Data?  // one of the peers will be asked to start the potato-passing; this function provides the data
    func youHaveThePotato(potato: Potato, finishBlock: @escaping (_ potato: Potato)->Void)
}

public protocol HandlesStateChanges {
    func didChangeState(from: HotPotatoNetwork.State, to: HotPotatoNetwork.State)
    func showError(type: HotPotatoNetwork.HPNError, title: String, message: String)
    func thesePeersAreMissing(peerNames: [String], dropBlock: @escaping ()->Void, keepWaitingBlock: @escaping ()->Void)
}

open class HotPotatoNetwork: CustomStringConvertible {
    
    open var bluepeer: BluepeerObject?
    open var rosterDelegate: BluepeerMembershipRosterDelegate?
    open var logDelegate: BluepeerLoggingDelegate?
    open var messageHandlers = [String:HandlesHotPotatoMessages]() // dict of message TYPE -> HotPotatoMessageHandler (one per message.type)
    open var potatoDelegate: HandlesPotato?
    open var stateDelegate: HandlesStateChanges?

    public enum State: Int {
        case buildup = 1
        case live
        case disconnect
    }
    public enum HPNError: Error {
        case versionMismatch
        case startClientCountMismatch
    }
    
    fileprivate var messageReplyQueue = [String:Queue<(HotPotatoMessage)->Void>]() // dict of message TYPE -> an queue of blocks that take a HotPotatoMessage. These are put here when people SEND data, as replyHandlers - they run max once.
    fileprivate var deviceIdentifier: String = UIDevice.current.name
    open var livePeerNames = [String:Int64]() // name->customdata[id]. peers that were included when Start button was pressed
    fileprivate var potatoLastPassedDates = [String:Date]()
    fileprivate var potato: Potato? {
        didSet {
            potatoLastSeen = Date.init()
        }
    }
    fileprivate var potatoLastSeen: Date = Date.init(timeIntervalSince1970: 0)
    fileprivate var potatoTimer: Timer?
    fileprivate var potatoTimerSeconds: TimeInterval!
    fileprivate var networkName: String!
    fileprivate var dataVersion: String! // ISO 8601 date
    
    fileprivate var state: State = .buildup {
        didSet {
            if oldValue == state {
                return
            }
            
            if oldValue == .buildup && state == .live {
                self.logDelegate?.logString("BUILDUP -> LIVE")
            } else if oldValue == .live && state == .disconnect {
                self.logDelegate?.logString("LIVE -> DISCONNECT")
            } else if oldValue == .disconnect && state == .live {
                self.logDelegate?.logString("DISCONNECT -> LIVE")
            } else {
                assert(false, "ERROR: invalid state transition")
            }
            
            self.stateDelegate?.didChangeState(from: oldValue, to: state)
        }
    }

    fileprivate var _messageID: Int = Int(arc4random_uniform(10000)) // start a random number so that IDs don't collide from different originators
    fileprivate var messageID: Int {
        get {
            return _messageID
        }
        set(newID) {
            if newID == Int.max-1 {
                _messageID = 0
            } else {
                _messageID = newID
            }
        }
    }
    
    // START message
    fileprivate var livePeersOnStart = 0
    fileprivate var startRepliesReceived = 0
    fileprivate var startHotPotatoMessageID = 0

    // BUILDGRAPH message
    fileprivate var buildGraphHotPotatoMessageID = 0
    fileprivate var missingPeersFromLiveList: [String]?

    // RECEIVING A POTATO -> PAYLOAD
    fileprivate var pendingPotatoHotPotatoMessage: PotatoHotPotatoMessage? // if not nil, then the next received data is the potato's data payload
    
    // all peers in this network must use the same name and version to connect and start. timeout is the amount of time the potato must be seen within, until it is considered a disconnect
    required public init(networkName: String, dataVersion: Date, timeout: TimeInterval? = 15.0) {
        self.networkName = networkName
        self.dataVersion = DateFormatter.ISO8601DateFormatter().string(from: dataVersion)
        self.potatoTimerSeconds = timeout
    }
    
    // removes me from the network, doesn't stop others from continuing in the network
    open func stop() {
        self.bluepeer!.stopAdvertising()
        self.bluepeer!.stopBrowsing()
        self.bluepeer!.dataDelegate = nil
        self.bluepeer!.membershipRosterDelegate = nil
        self.bluepeer!.membershipAdminDelegate = nil
        self.bluepeer!.logDelegate = nil
        self.bluepeer!.disconnectSession()
    }
    
    open func startLookingForPotatoPeers() {
        var bluepeerServiceName = self.networkName!
        if bluepeerServiceName.characters.count > 15 {
            bluepeerServiceName = bluepeerServiceName.substring(to: bluepeerServiceName.index(bluepeerServiceName.startIndex, offsetBy:14))
        }
        print("HPN: startConnecting, Bluepeer service name: \(bluepeerServiceName), device: \(self.deviceIdentifier) / \(self.deviceIdentifier.hashValue)")
        self.bluepeer = BluepeerObject.init(serviceType: bluepeerServiceName, displayName: deviceIdentifier, queue: nil, serverPort: XaphodUtils.getFreeTCPPort(), interfaces: .infrastructureModeWifiOnly, bluetoothBlock: nil)!
        if let logDel = self.logDelegate {
            self.bluepeer?.logDelegate = logDel
        }

        self.bluepeer!.dataDelegate = self
        self.bluepeer!.membershipAdminDelegate = self
        self.bluepeer!.membershipRosterDelegate = self
        self.bluepeer!.startBrowsing()
        self.bluepeer!.startAdvertising(.any, customData: ["id":String(self.deviceIdentifier.hashValue)])
    }
    
    fileprivate func snapPeerListNow() {
        for peer in bluepeer!.connectedPeers() {
            let peerId: String = peer.customData!["id"] as! String
            let peerIdInt = Int64(peerId)!
            livePeerNames[peer.displayName] = peerIdInt
        }
        livePeerNames[self.bluepeer!.displayNameSanitized] = Int64(self.deviceIdentifier.hashValue)
        self.logDelegate?.logString("Live peer list has been set to: \(livePeerNames)")
    }
    
    fileprivate func emptyPeerListNow() {
        livePeerNames = [String:Int64]()
    }
    
    open var description: String {
        return self.bluepeer?.description ?? "Bluepeer not initialized"
    }
    
    // MARK:
    // MARK: SENDING MESSAGES & CONNECTIONS
    // MARK:
    
    open func sendHotPotatoMessage(message: HotPotatoMessage, replyBlock: ((HotPotatoMessage)->Void)?) {
        guard let str: String = message.toJSONString(prettyPrint: false), let data = str.data(using: .utf8) else {
            assert(false, "ERROR can't make data out of HotPotatoMessage")
            return
        }
        do {
            self.prepReplyQueueWith(replyBlock: replyBlock, message: message)
            try self.bluepeer!.sendData([data], toRole: .any)
            if let message = message as? PotatoHotPotatoMessage, let payload = message.potato?.payload {
                try self.bluepeer!.sendData([payload], toRole: .any)
            }
        } catch {
            assert(false, "ERROR got error on sendData: \(error)")
        }
    }
    
    open func sendHotPotatoMessage(message: HotPotatoMessage, toPeer: BPPeer, replyBlock: ((HotPotatoMessage)->Void)?) {
        guard let str: String = message.toJSONString(prettyPrint: false), let data = str.data(using: .utf8) else {
            assert(false, "ERROR can't make data out of HotPotatoMessage")
            return
        }
        do {
            self.prepReplyQueueWith(replyBlock: replyBlock, message: message)
            try self.bluepeer!.sendData([data], toPeers: [toPeer])
            if let message = message as? PotatoHotPotatoMessage, let payload = message.potato?.payload {
                try self.bluepeer!.sendData([payload], toPeers: [toPeer])
            }
        } catch {
            assert(false, "ERROR got error on sendData: \(error)")
        }
    }
    
    fileprivate func prepReplyQueueWith(replyBlock: ((HotPotatoMessage)->Void)?, message: HotPotatoMessage) {
        if let replyBlock = replyBlock {
            let key = message.classNameAsString()
            if self.messageReplyQueue[key] == nil {
                self.messageReplyQueue[key] = Queue<(HotPotatoMessage)->Void>()
            }
            
            self.messageReplyQueue[key]!.enqueue(replyBlock)
        }
    }
    
    fileprivate func connectionAllowedFrom(peer: BPPeer) -> Bool {
        if self.livePeerNames.count > 0 {
            if let _ = self.livePeerNames[peer.displayName] {
                self.logDelegate?.logString(("HPN: livePeerNames contains this peer, allowing connection"))
                return true
            } else {
                self.logDelegate?.logString(("HPN: livePeerNames is non-empty and DOES NOT contain \(peer.displayName), NOT ALLOWING CONNECTION"))
                return false
            }
        } else {
            self.logDelegate?.logString(("HPN: no livePeerNames so we're in buildup phase - allowing all connections"))
            return true
        }
    }
    
    fileprivate func connectToPeer(_ peer: BPPeer) {
        if self.connectionAllowedFrom(peer: peer) == false {
            return
        }
        
        guard let remoteID = peer.customData?["id"] as? String, let remoteIDInt = Int64(remoteID) else {
            self.logDelegate?.logString("HPN: ERROR, remote ID missing/invalid - \(String(describing: peer.customData?["id"]))")
            return
        }
        if remoteIDInt > Int64(self.deviceIdentifier.hashValue) {
            self.logDelegate?.logString("HPN: remote ID(\(remoteIDInt)) bigger than mine(\(self.deviceIdentifier.hashValue)), initiating connection...")
            peer.connect!()
        } else {
            self.logDelegate?.logString("HPN: remote ID(\(remoteIDInt)) smaller than mine(\(self.deviceIdentifier.hashValue)), no-op.")
        }
    }
    
    // MARK:
    // MARK: POTATO
    // MARK:

    
    fileprivate func startPotatoNow() {
        assert(livePeerNames.count > 0, "ERROR")
        guard let payload = self.potatoDelegate?.youStartThePotato() else {
            assert(false, "ERROR set potatoDelegate first, and make sure it can always give me a copy of the payload Data")
            return
        }
        for peerName in livePeerNames {
            potatoLastPassedDates[peerName.0] = Date.init(timeIntervalSince1970: 0)
        }
        potatoLastPassedDates.removeValue(forKey: self.bluepeer!.displayNameSanitized)
        // highest hash of peernames wins
        let winner: (String, Int64) = livePeerNames.reduce(("",Int64.min)) { (result, element) -> (String,Int64) in
            return element.value >= result.1 ? element : result
        }
        if self.bluepeer!.displayNameSanitized == winner.0 {
            self.logDelegate?.logString("startPotatoNow: I'M THE WINNER")
            let firstVisit = self.generatePotatoVisit()
            self.potato = Potato.init(payload: payload, visits: [firstVisit])
            self.passPotato()
        } else {
            self.logDelegate?.logString("startPotatoNow: I didn't win, \(winner) did")
            self.restartPotatoTimer()
        }
    }
    
    fileprivate func passPotato() {
        if state == .disconnect || self.bluepeer!.connectedPeers().count == 0 {
            self.logDelegate?.logString("NOT passing potato as state=disconnect")
            return
        }
        
        let oldestPeer: (String,Date) = self.potatoLastPassedDates.reduce(("", Date.distantFuture)) { (result, element) -> (String, Date) in
            let peers = self.bluepeer!.peers.filter({ $0.displayName == element.0 })
            if peers.count != 1 {
                assert(false, "ERROR: no peer found")
                return result
            }
            let peer = peers.first!
            if peer.state != .authenticated {
                self.logDelegate?.logString("passPotato: \(peer.displayName) not connected, not passing to them...")
                return result
            }
            return result.1 < element.1 ? result : element
        }
        
        if oldestPeer.0 == "" {
            self.logDelegate?.logString("potatoPassBlock: FOUND NO PEER TO PASS TO, TRYING AGAIN IN 2 SECONDS")
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: {
                self.passPotato()
            })
            return
        }
        
        self.logDelegate?.logString("potatoPassBlock: passing to \(oldestPeer.0)")
        
        // update meta: passedDates, potato.visits
        self.potatoLastPassedDates[oldestPeer.0] = Date.init()
        var visits: [PotatoVisit] = Array(potato!.visits!.suffix(MaxPotatoVisitLength-1))
        visits.append(self.generatePotatoVisit())
        potato!.visits = visits
        
        let potatoHotPotatoMessage = PotatoHotPotatoMessage.init(potato: potato!)
        
        self.sendHotPotatoMessage(message: potatoHotPotatoMessage, toPeer: self.bluepeer!.peers.filter({ $0.displayName == oldestPeer.0 }).first!, replyBlock: nil)
        self.restartPotatoTimer()
    }
    
    fileprivate func generatePotatoVisit() -> PotatoVisit {
        var visitNum = 1
        if let potato = self.potato { // should be true every time except the first one
            visitNum = potato.visits!.last!.visitNum! + 1
        }
        let connectedPeers = self.bluepeer!.connectedPeers().map({ $0.displayName })
        let visit = PotatoVisit.init(peerName: self.bluepeer!.displayNameSanitized, visitNum: visitNum, connectedPeers: connectedPeers)
        self.logDelegate?.logString("generatePotatoVisit: generated \(visit)")
        return visit
    }
    
    fileprivate func restartPotatoTimer() {
        if let timer = self.potatoTimer {
            timer.invalidate()
            self.potatoTimer = nil
        }
        self.potatoTimer = Timer.scheduledTimer(timeInterval: potatoTimerSeconds, target: self, selector: #selector(potatoTimerFired(timer:)), userInfo: nil, repeats: false)
    }
    
    @objc fileprivate func potatoTimerFired(timer: Timer) {
        let timeSincePotatoLastSeen = abs(self.potatoLastSeen.timeIntervalSinceNow)
        self.logDelegate?.logString("Potato Timer Fired. Last seen: \(timeSincePotatoLastSeen)")
        
        if timeSincePotatoLastSeen > potatoTimerSeconds {
            // state: disconnect
            self.logDelegate?.logString("POTATO TIMER SETS STATE=DISCONNECT, sending BuildGraph messages")
            self.state = .disconnect
            DispatchQueue.main.asyncAfter(deadline: .now() + potatoTimerSeconds, execute: {
                // delay so that all devices can get to disconnect state before they respond to our BuildGraph message!
                self.sendBuildGraphHotPotatoMessage()
            })
        }
    }
    
    fileprivate func handlePotatoHotPotatoMessage(_ potatoHotPotatoMessage: PotatoHotPotatoMessage, peer: BPPeer) {
        self.potato = potatoHotPotatoMessage.potato!
        self.logDelegate?.logString("HPN: got potato from \(peer.displayName).")
        assert(self.potatoLastPassedDates[peer.displayName] != nil, "ERROR")
        self.potatoLastPassedDates[peer.displayName] = Date.init()
        
        // if we're disconnected, then consider this a reconnection
        self.state = .live
        
        self.potatoDelegate?.youHaveThePotato(potato: self.potato!, finishBlock: { (potato) in
            self.potato = potato
            self.passPotato()
        })
    }
    
    // MARK:
    // MARK: BUILDGRAPH - used on disconnects to ping and find out who is still around
    // MARK:
    
    fileprivate func sendBuildGraphHotPotatoMessage() {
        self.missingPeersFromLiveList = self.livePeerNames.map { $0.key }
        if let index = self.missingPeersFromLiveList!.index(of: bluepeer!.displayNameSanitized) {
            self.missingPeersFromLiveList!.remove(at: index) // remove myself from the list of missing peers
        }
        
        let _ = bluepeer!.connectedPeers().map { // remove peers im already connected to
            if let index = self.missingPeersFromLiveList!.index(of: $0.displayName) {
                self.missingPeersFromLiveList!.remove(at: index)
            }
        }

        self.logDelegate?.logString("HPN: sendBuildGraphHotPotatoMessage(), missing peers: \(self.missingPeersFromLiveList!.joined(separator: ", "))")
        
        // important: don't call sendRecoverHotPotatoMessage already even if there are no missing peers, because we might be the only one disconnected from a fully-connnected network. Wait for responses first.
        self.buildGraphHotPotatoMessageID = messageID + 1
        let buildgraph = BuildGraphHotPotatoMessage.init(myConnectedPeers: bluepeer!.connectedPeers().map({ $0.displayName }), myState: state, livePeerNames: self.livePeerNames, ID: self.buildGraphHotPotatoMessageID)
        sendHotPotatoMessage(message: buildgraph, replyBlock: nil)
    }
    
    fileprivate func sendRecoverHotPotatoMessage(withLivePeers: [String:Int64]) {
        if state != .disconnect {
            self.logDelegate?.logString("HPN: WARNING, skipping sendRecoverHotPotatoMessage() since we're not state=disconnect!")
            return
        }
        
        self.logDelegate?.logString("HPN: sendRecoverHotPotatoMessage, withLivePeers: \(withLivePeers)")
        self.livePeerNames = withLivePeers
        assert(livePeerNames.count > 0, "ERROR")
        self.state = .live // get .live before sending out to others.
        
        // send RecoverHotPotatoMessage, with live peers
        messageID += 1
        let recover = RecoverHotPotatoMessage.init(ID: messageID, livePeerNames: withLivePeers)
        
        // don't just call handleRecoverHotPotatoMessage, as we want to ensure the recoverMessage arrives at the remote side before the actual potato does (in the case where we win the startPotato election)
        sendHotPotatoMessage(message: recover, replyBlock: nil)
        startPotatoNow()
    }
    
    fileprivate func handleBuildGraphHotPotatoMessage(message: BuildGraphHotPotatoMessage, peer: BPPeer) {
        self.logDelegate?.logString("HPN: handleBuildGraphHotPotatoMessage from \(peer.displayName). remoteConnectedPeers: \(message.myConnectedPeers!.joined(separator: ", ")), state=\(String(describing: State(rawValue: message.myState!.rawValue)!)), livePeerNames: \(message.livePeerNames!)")
        if message.ID! == self.buildGraphHotPotatoMessageID {
            self.logDelegate?.logString("... handling \(peer.displayName)'s response to my BuildGraphHotPotatoMessage")
            
            if state != .disconnect {
                self.logDelegate?.logString("HPN: state!=disconnect, so no-op")
                return
            }
            if message.myState! != .disconnect { // expectation: they've seen the potato recently and we're connected to them, so just wait for potato to be passed to me
                self.logDelegate?.logString("HPN: \(peer.displayName)'s state!=disconnect, so no-op")
                return
            }

            guard var missing = self.missingPeersFromLiveList else {
                assert(false, "ERROR")
                return
            }
            if let index = missing.index(of: peer.displayName) {
                missing.remove(at: index)
            }
            let _ = message.myConnectedPeers!.map { // remote side's connected peers
                if let index = missing.index(of: $0) {
                    missing.remove(at: index)
                }
            }
            self.missingPeersFromLiveList = missing
            if self.missingPeersFromLiveList!.count == 0 {
                // restart the potato
                self.sendRecoverHotPotatoMessage(withLivePeers: self.livePeerNames)
            } else {
                // tell delegate the updated list
                self.stateDelegate?.thesePeersAreMissing(peerNames: self.missingPeersFromLiveList!, dropBlock: {
                    // this code will get run if these peers are supposed to be dropped.
                    var updatedLivePeers = self.livePeerNames
                    let _ = missing.map {
                        updatedLivePeers.removeValue(forKey: $0)
                    }
                    self.sendRecoverHotPotatoMessage(withLivePeers: updatedLivePeers)
                }, keepWaitingBlock: {
                    // this code will get run if the user wants to keep waiting
                    self.sendBuildGraphHotPotatoMessage()
                })
            }
        } else {
            self.logDelegate?.logString("... replying to BuildGraphHotPotatoMessage from \(peer.displayName)")
            let reply = BuildGraphHotPotatoMessage.init(myConnectedPeers: bluepeer!.connectedPeers().map({ $0.displayName }), myState: state, livePeerNames: self.livePeerNames, ID: message.ID!)
            sendHotPotatoMessage(message: reply, toPeer: peer, replyBlock: nil)
        }
    }
    
    fileprivate func handleRecoverHotPotatoMessage(message: RecoverHotPotatoMessage, peer: BPPeer?) {
        let name = peer?.displayName ?? "myself"
        self.livePeerNames = message.livePeerNames!
        self.logDelegate?.logString("Got handleRecoverHotPotatoMessage from \(name), new livePeers are \(message.livePeerNames!), going live and starting potato now")
        if state != .disconnect {
            self.logDelegate?.logString("handleRecoverHotPotatoMessage: not .disconnect, no-op")
            return
        }
        self.state = .live
        startPotatoNow()
    }
    
    // MARK:
    // MARK: STARTING
    // MARK:
    
    open func startNetwork() -> Bool {
        let connectedPeersCount = bluepeer!.connectedPeers().count
        if connectedPeersCount == 0 {
            self.logDelegate?.logString("Aborting startButton - no connected peers")
            return false
        }
        
        self.logDelegate?.logString("Sending initial start message, \(connectedPeersCount) connected peers")
        self.startRepliesReceived = 0
        self.livePeersOnStart = connectedPeersCount
        messageID += 1
        self.startHotPotatoMessageID = messageID
        let startHotPotatoMessage = StartHotPotatoMessage(remoteDevices: connectedPeersCount, dataVersion: self.dataVersion, ID: messageID, livePeerNames: nil)
        sendHotPotatoMessage(message: startHotPotatoMessage, replyBlock: nil)
        return true
    }
    
    fileprivate func handleStartHotPotatoMessage(startHotPotatoMessage: StartHotPotatoMessage, peer: BPPeer) {
        self.logDelegate?.logString("Received StartHotPotatoMessage, ID: \(String(describing: startHotPotatoMessage.ID))")
        if state != .buildup {
            self.logDelegate?.logString("WARNING - ignoring startHotPotatoMessage because state != .buildup")
            return
        }
        
        if startHotPotatoMessage.dataVersion! != self.dataVersion {
            let dateformatter = DateFormatter.init()
            dateformatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssSSSSZZZZZ"
            let remoteVersionDate = dateformatter.date(from: startHotPotatoMessage.dataVersion!)!
            let myVersionDate = dateformatter.date(from: self.dataVersion)!
            self.stateDelegate?.showError(type: .versionMismatch, title: "Error", message: "This device has \(myVersionDate < remoteVersionDate ? "an earlier" : "a more recent") version of the data payload than \(peer.displayName).")
            self.logDelegate?.logString("WARNING - data version mismatch, disconnecting \(peer.displayName)")
            peer.disconnect()
            return
        }
        
        // go live message - regardless of whether i pressed start or someone else did
        if let livePeers = startHotPotatoMessage.livePeerNames {
            if let _ = livePeers[bluepeer!.displayNameSanitized] {
                livePeerNames = livePeers
                self.state = .live
                self.logDelegate?.logString("Received StartHotPotatoMessage GO LIVE from \(peer.displayName), set livePeerNames to \(livePeers)")
                startPotatoNow()
            } else {
                self.logDelegate?.logString("Received StartHotPotatoMessage GO LIVE from \(peer.displayName), but I AM NOT INCLUDED IN \(livePeers), disconnecting")
                peer.disconnect()
            }
            return
        }
        
        if startHotPotatoMessage.ID! == self.startHotPotatoMessageID {
            // this is a reply to me sending START. Looking to see number of replies (ie. from n-1 peers), that we all see the same number of peers, and that the data version matches
            
            if startHotPotatoMessage.remoteDevices! != self.livePeersOnStart || self.livePeersOnStart != bluepeer!.connectedPeers().count {
                self.logDelegate?.logString("WARNING - remote peer count mismatch, or my connCount has changed since start pressed")
                self.stateDelegate?.showError(type: .startClientCountMismatch, title: "Try Again", message: "Please try again when all devices are connected to each other")
                return
            }
            
            self.startRepliesReceived += 1
            if self.startRepliesReceived == self.livePeersOnStart {
                // got all the replies
                self.logDelegate?.logString("Received StartHotPotatoMessage reply from \(peer.displayName), done, going LIVE and telling everyone")
                snapPeerListNow() // TODO: saw a crash here once because the customData of the peer was empty. how?
                self.state = .live
                messageID += 1
                assert(livePeerNames.count > 0, "ERROR")
                let golive = StartHotPotatoMessage(remoteDevices: self.livePeersOnStart, dataVersion: self.dataVersion, ID: messageID, livePeerNames: livePeerNames)
                sendHotPotatoMessage(message: golive, replyBlock: nil)
                startPotatoNow()
            } else {
                self.logDelegate?.logString("Received StartHotPotatoMessage reply from \(peer.displayName), waiting for \(self.livePeersOnStart - self.startRepliesReceived) more")
            }
        } else {
            // someone else hit START - reply to them with what I know
            let reply = StartHotPotatoMessage(remoteDevices: bluepeer!.connectedPeers().count, dataVersion: self.dataVersion, ID: startHotPotatoMessage.ID!, livePeerNames: nil)
            sendHotPotatoMessage(message: reply, toPeer: peer, replyBlock: nil)
        }
    }
}

extension HotPotatoNetwork : BluepeerMembershipAdminDelegate {
    public func browserFoundPeer(_ role: RoleType, peer: BPPeer) {
        self.connectToPeer(peer)
    }

    public func peerConnectionRequest(_ peer: BPPeer, invitationHandler: @escaping (Bool) -> Void) {
        if self.connectionAllowedFrom(peer: peer) == false {
            invitationHandler(false)
        } else {
            invitationHandler(true)
        }
    }
}

extension HotPotatoNetwork : BluepeerMembershipRosterDelegate {
    public func peerConnectionAttemptFailed(_ peerRole: RoleType, peer: BPPeer?, isAuthRejection: Bool, canConnectNow: Bool) {
        self.logDelegate?.logString("HPN: peerConnectionAttemptFailed for \(String(describing: peer?.displayName))!")
        if (isAuthRejection) {
            self.logDelegate?.logString("HPN: peerConnectionAttemptFailed, AuthRejection!")
        }
        if let peer = peer, canConnectNow == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0, execute: { // otherwise it eats 100% CPU when looping fast
                self.logDelegate?.logString("HPN: peerConnectionAttemptFailed, canConnectNow - reconnecting...")
                self.connectToPeer(peer)
            })
        }
    }
    
    public func peerDidConnect(_ peerRole: RoleType, peer: BPPeer) {
        self.rosterDelegate?.peerDidConnect?(peerRole, peer: peer)

        if state == .disconnect {
            self.sendBuildGraphHotPotatoMessage()
        }
    }
    
    public func peerDidDisconnect(_ peerRole: RoleType, peer: BPPeer, canConnectNow: Bool) {
        self.rosterDelegate?.peerDidDisconnect?(peerRole, peer: peer, canConnectNow: canConnectNow)
        if canConnectNow {
            self.logDelegate?.logString("HPN: peerDidDisconnect, canConnectNow - reconnecting...")
            self.connectToPeer(peer)
        }
    }
}

extension HotPotatoNetwork : BluepeerDataDelegate {
    public func didReceiveData(_ data: Data, fromPeer peer: BPPeer) {
        if let pendingPotatoHotPotatoMessage = self.pendingPotatoHotPotatoMessage {
            // then this data is part of the potato message
            self.logDelegate?.logString("Received potato PAYLOAD")
            pendingPotatoHotPotatoMessage.potato!.payload = data
            self.pendingPotatoHotPotatoMessage = nil
            self.handlePotatoHotPotatoMessage(pendingPotatoHotPotatoMessage, peer: peer)
            return
        }
        
        guard let stringReceived = String(data: data, encoding: .utf8),
            let message = Mapper<HotPotatoMessage>().map(JSONString: stringReceived) else {
            assert(false, "ERROR: received something that isn't UTF8 string, or can't map the string")
            return
        }
        
        let key = message.classNameAsString()
        self.logDelegate?.logString("Received message of type \(key)")
        
        // HotPotatoMessages I handle
        if let potatoHotPotatoMessage = message as? PotatoHotPotatoMessage {
            self.pendingPotatoHotPotatoMessage = potatoHotPotatoMessage
            return
        } else if let startmessage = message as? StartHotPotatoMessage {
            self.handleStartHotPotatoMessage(startHotPotatoMessage: startmessage, peer: peer)
            return
        } else if let buildgraphmessage = message as? BuildGraphHotPotatoMessage {
            self.handleBuildGraphHotPotatoMessage(message: buildgraphmessage, peer: peer)
            return
        } else if let recovermessage = message as? RecoverHotPotatoMessage {
            self.handleRecoverHotPotatoMessage(message: recovermessage, peer: peer)
            return
        }
        
        // HotPotatoMessages handled elsewhere
        if var queue = self.messageReplyQueue[key], let replyBlock = queue.dequeue() {
            //self.logDelegate?.logString("Found handler in messageReplyQueue, using that")
            replyBlock(message)
        } else if let handler = self.messageHandlers[key], handler.isActiveAsHandler == true {
            //self.logDelegate?.logString("Found handler in messageHandlers, using that")
            handler.handleHotPotatoMessage(message: message, peer: peer, HPN: self)
        } else {
            assert(false, "ERROR: unhandled message - \(message)")
        }
    }
}

public extension DateFormatter {
    class func ISO8601DateFormatter() -> DateFormatter {
        let retval = DateFormatter.init()
        retval.dateFormat = "yyyy-MM-dd'T'HH:mm:ssSSSSZZZZZ"
        return retval
    }
}

public extension Date {
    // warning, english only
    func relativeTimeStringFromNow() -> String {
        let dateComponents = Calendar.current.dateComponents([.minute, .hour, .day, .weekOfYear], from: self, to: Date.init())
        if dateComponents.weekOfYear! == 0 && dateComponents.day! == 0  && dateComponents.hour! == 0 {
            if dateComponents.minute! <= 1 {
                return "just now"
            }
            // show minutes
            return "\(dateComponents.minute!) minute(s) ago"
        } else if dateComponents.weekOfYear! == 0 && dateComponents.day! == 0 {
            // show hours
            return "\(dateComponents.hour!) hour(s) ago"
        } else if dateComponents.weekOfYear! < 2 {
            // show days
            let days = dateComponents.weekOfYear! * 7 + dateComponents.day!
           return "\(days) day(s) ago"
        } else {
            // show weeks
            return "\(dateComponents.weekOfYear!) week(s) ago"
        }
    }
}

