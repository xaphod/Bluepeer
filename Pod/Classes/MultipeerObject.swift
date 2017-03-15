//
//  MultipeerObject.swift
//  BluePrint
//
//  Created by Tim Carr on 6/23/16.
//  Copyright © 2016 Tim Carr. All rights reserved.
//

import Foundation
import MultipeerConnectivity
import CoreBluetooth

@objc public protocol MultipeerSessionManagerDelegate {
    @objc optional func peerDidConnect(_ session: MCSession?, peerRole: RoleType, peer: MCPeerID)
    @objc optional func peerDidDisconnect(_ session: MCSession?, peerRole: RoleType, peer: MCPeerID)
    @objc optional func peerConnectionAttemptFailed(_ session: MCSession?, peerRole: RoleType, peer: MCPeerID)
    @objc optional func sessionConnectionRequest(_ session: MCSession, peer: MCPeerID, context: Data?, invitationHandler: (Bool, MCSession) -> Void)
    @objc optional func browserFoundPeer(_ role: RoleType, peer: MCPeerID, discoveryInfo: [String : String]?, inviteBlock: (_ timeoutForInvite: TimeInterval) -> Void)
}

@objc public protocol MultipeerDataDelegate {
    func didReceiveData(_ data: Data, fromPeer peerID: MCPeerID)
    @objc optional func failedToStartAdvertising(_ error: NSError)
    @objc optional func failedToStartBrowsing(_ error: NSError)
}

@objc open class MultipeerObject: NSObject, MCNearbyServiceAdvertiserDelegate, MCSessionDelegate, MCBrowserViewControllerDelegate, CBPeripheralManagerDelegate, MCNearbyServiceBrowserDelegate {
    
    var delegateQueue: DispatchQueue?
    open var serviceType: String
    var myID: MCPeerID
    var versionString: String = "unknown"
    var advertiser: MCNearbyServiceAdvertiser?
    var browser: MCNearbyServiceBrowser?
    var activeSession: MCSession
    weak open var sessionDelegate: MultipeerSessionManagerDelegate?
    weak open var dataDelegate: MultipeerDataDelegate?
    open var peers: [MCPeerID:(role: RoleType, state: MCSessionState)]? = [:]
    open var bluetoothState : BluetoothState = .unknown
    var browserCompletionBlock: ((_ success: Bool) -> Void)?
    var bluetoothPeripheralManager: CBPeripheralManager
    open var bluetoothBlock: ((_ bluetoothState: BluetoothState) -> Void)?
    open var disconnectOnWillResignActive: Bool = false {
        didSet {
            if disconnectOnWillResignActive {
                NotificationCenter.default.addObserver(self, selector: #selector(willResignActive), name: NSNotification.Name.UIApplicationWillResignActive, object: nil)
            } else {
                NotificationCenter.default.removeObserver(self, name: NSNotification.Name.UIApplicationWillResignActive, object: nil)
            }
        }
    }
    
    // if queue isn't given, main queue is used
    public init(serviceType: String, displayName:String?, encryptionPreference: MCEncryptionPreference, queue:DispatchQueue?, bluetoothBlock: ((_ bluetoothState: BluetoothState)->Void)?) { // serviceType must be 1-15 chars, only a-z0-9 and hyphen, eg "xd-blueprint"
        self.serviceType = serviceType
        self.delegateQueue = queue
        self.bluetoothPeripheralManager = CBPeripheralManager.init(delegate: nil, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey:0])
        if let name = displayName {
            myID = MCPeerID.init(displayName: name)
        } else {
            myID = MCPeerID.init(displayName: UIDevice.current.name)
        }
        
        if let bundleVersionString = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            versionString = bundleVersionString
        }
        self.activeSession = MCSession.init(peer: self.myID, securityIdentity: nil, encryptionPreference: encryptionPreference)

        NSLog("MultipeerObject init for service \(serviceType), bundle version: \(versionString)")
        super.init()
        
        self.bluetoothBlock = bluetoothBlock
        self.bluetoothPeripheralManager = CBPeripheralManager.init(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey:0])
        self.activeSession.delegate = self
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // Note: only disconnect is handled. My delegate is expected to reconnect if needed.
    func willResignActive() {
        NSLog("MultipeerObject: willResignActive, disconnecting.")
        stopBrowsing()
        stopAdvertising()
        disconnectSession()
        dataDelegate = nil
        sessionDelegate = nil
    }

    open func disconnectSession() {
        self.activeSession.disconnect()
    }
    
    open func connectedRoleCount(_ role: RoleType) -> Int {
        guard let _ = self.peers else {
            return 0
        }
        return self.peers!.filter({ $0.1.role == role && $0.1.state == .connected }).count
    }
    
    open func startAdvertising(_ role: RoleType) {
        advertiser = MCNearbyServiceAdvertiser.init(peer: myID, discoveryInfo: ["version":versionString, "role":(role == .server ? "Server" : "Client")], serviceType: serviceType)
        advertiser?.delegate = self;
        advertiser?.startAdvertisingPeer()
        NSLog("Multipeer: now advertising as role \(role == .server ? "Server" : "Client") for service \(serviceType)")
    }
    
    open func stopAdvertising() {
        if let advertiser = self.advertiser {
            advertiser.stopAdvertisingPeer()
            advertiser.delegate = nil
            self.advertiser = nil
            NSLog("Multipeer: advertising stopped")
        }
    }
    
    open func startBrowsing() {
        self.browser = MCNearbyServiceBrowser.init(peer: myID, serviceType: serviceType)
        self.browser?.delegate = self
        self.browser?.startBrowsingForPeers()
        NSLog("Multipeer: now browsing for service \(serviceType)")
    }
    
    open func stopBrowsing() {
        self.browser?.stopBrowsingForPeers()
        self.browser?.delegate = nil
        self.browser = nil
    }
    
    
    // If specified, peers takes precedence.
    open func sendData(_ datas: [Data]!, toPeers:[MCPeerID]?, toRole: RoleType) throws {
        if let peers = self.peers {
            var targetPeers: [MCPeerID]
            if let toPeers = toPeers {
                targetPeers = toPeers
            } else {
                let peersArray: [(MCPeerID, (role: RoleType, state: MCSessionState))] = peers.filter({
                    if toRole != .any {
                        return $0.1.role == toRole && $0.1.state == .connected
                    } else {
                        return $0.1.state == .connected
                    }
                })
                targetPeers = peersArray.map({$0.0})
            }
            
            for data in datas {
                NSLog("Multipeer sending to %d peers", targetPeers.count)
                try self.activeSession.send(data, toPeers: targetPeers, with: .reliable)
            }
        }
    }
    
    func registerPeer(_ peerID: MCPeerID, info: [String : String]?) -> RoleType {
        var retval = RoleType.unknown
        if let info = info {
            if let role = info["role"] {
                // save roles for later!
                if let _ = self.peers {
                    switch role {
                    case "Server":
                        retval = .server
                        NSLog("Multipeer Browser found a server: \(peerID.displayName)")
                    case "Client":
                        retval = .client
                        NSLog("Multipeer Browser found a client: \(peerID.displayName)")
                    default:
                        retval = .client
                        NSLog("Multipeer Browser found unknown type, presuming client!!!: \(peerID.displayName)")
                    }
                    
                    self.peers!.updateValue((retval, .notConnected), forKey: peerID)
                }
            }
            if let ver = info["version"] {
                if (ver == self.versionString) {
                    NSLog("Multipeer: Peer has same version of MultipeerObject as me.")
                } else {
                    NSLog("Multipeer: Peer DOES NOT have same version of MultipeerObject as me.")
                }
            }
        } else {
            NSLog("Multipeer ERROR: no discoveryInfo found! Not registering peer.")
        }
        return retval
    }
    
    open func getBrowser(_ browserCompletionBlock: ((_ success: Bool) -> Void)?) -> MCBrowserViewController? {
        self.browserCompletionBlock = browserCompletionBlock
        let browserViewController = MCBrowserViewController.init(serviceType: self.serviceType, session: self.activeSession)
        browserViewController.delegate = self
        return browserViewController
    }
    
    // MCNearbyServiceBrowserDelegate
    open func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        let role = self.registerPeer(peerID, info: info)
        
        if let delegate = self.sessionDelegate {
            self.dispatch_on_delegate_queue({
                delegate.browserFoundPeer?(role, peer: peerID, discoveryInfo: info, inviteBlock: { (timeoutForInvite) in
                    browser.invitePeer(peerID, to: self.activeSession, withContext: nil, timeout: timeoutForInvite)
                })
            })
        }
    }
    
    open func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        NSLog("Multipeer lost peer: \(peerID.displayName)")
        if var peers = self.peers {
            if let oldVal = peers[peerID] {
                peers.updateValue((oldVal.role, .notConnected), forKey: peerID)
            }
        }
    }
    
    open func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        NSLog("Multipeer browser failed to start: \(error)")
        if let delegate = self.dataDelegate {
            self.dispatch_on_delegate_queue({
                delegate.failedToStartBrowsing?(error as NSError)
            })
        }
    }

    
    // MCNearbyServiceAdvertiserDelegate
    
    open func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        NSLog("ERROR: could not start advertising. Error: \(error)")
        if let delegate = self.dataDelegate {
            self.dispatch_on_delegate_queue({
                delegate.failedToStartAdvertising?(error as NSError)
            })
        }
    }
    
    open func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        NSLog("Invitation received from peer \(peerID.displayName)")
        
        if let delegate = self.sessionDelegate {
            self.dispatch_on_delegate_queue({
                delegate.sessionConnectionRequest?(self.activeSession, peer: peerID, context: context, invitationHandler: invitationHandler)
            })
        }
    }
    
    
    // MCSessionDelegate
    
    open func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        // TODO: BUG - when two clients print at same time, their data gets mixed up together somehow
        NSLog("\(#function) - peer: \(peerID.displayName)")
        if let delegate = self.dataDelegate {
            self.dispatch_on_delegate_queue({
                delegate.didReceiveData(data, fromPeer: peerID)
            })
        }
    }
    
    open func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        self.dispatch_on_delegate_queue({
            let stateString = state == .connected ? "Connected" : (state == .connecting ? "Connecting" : "Not connected")
            NSLog("\(#function) - peer: \(peerID.displayName), state: \(stateString)")
            
            if (state == .connected) {
                if self.peers![peerID] == nil {
                    // if we are connected, and it's not in the dict, then we are a server, so it is a client
                    NSLog("Adding new connected peer \(peerID.displayName), assuming it is a CLIENT")
                    self.peers![peerID] = (.client, .connected)
                } else {
                    NSLog("Marking existing peer \(peerID.displayName) as connected. Role = \((self.peers![peerID]!.role == .server ? "Server" : "Client"))")
                    self.peers![peerID]?.state = .connected
                }
                
                if let delegate = self.sessionDelegate {
                    delegate.peerDidConnect?(session, peerRole: self.peers![peerID]!.role, peer: peerID)
                }
            } else if (state == .notConnected) {
                
                if self.peers![peerID] != nil {
                    let oldState = self.peers![peerID]!.state
                    let role = self.peers![peerID]!.role
                    if (oldState == .connected) {
                        self.peers![peerID] = nil
                        if let delegate = self.sessionDelegate {
                            delegate.peerDidDisconnect?(session, peerRole: role, peer: peerID)
                        }
                    } else {
                        self.peers![peerID]!.state = state
                        if (oldState == .connecting) {
                            if let delegate = self.sessionDelegate {
                                delegate.peerConnectionAttemptFailed?(session, peerRole: role, peer: peerID)
                            }
                        }
                    }
                }
            } else if (state == .connecting) {
                self.peers![peerID]?.state = .connecting
            }
        })
    }
    
    open func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        NSLog("\(#function) - peer: \(peerID.displayName)")
    }
    
    open func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {
        NSLog("\(#function) - peer: \(peerID.displayName)")
    }
    
    open func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL, withError error: Error?) {
        NSLog("\(#function) - peer: \(peerID.displayName)")
    }
    
    
    // MCBrowserViewControllerDelegate
    open func browserViewControllerDidFinish(_ browserViewController: MCBrowserViewController) {
        if let completionBlock = self.browserCompletionBlock {
            DispatchQueue.main.async(execute: {
                completionBlock(true)
                self.browserCompletionBlock = nil
            })
        }
    }
    
    open func browserViewControllerWasCancelled(_ browserViewController: MCBrowserViewController) {
        if let completionBlock = self.browserCompletionBlock {
            DispatchQueue.main.async(execute: {
                completionBlock(false)
                self.browserCompletionBlock = nil
            })
        }
    }
    
    open func browserViewController(_ browserViewController: MCBrowserViewController, shouldPresentNearbyPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) -> Bool {
        
        var retval = false
        
        let work = {
            let role = self.registerPeer(peerID, info: info)
            if (role == .server) {
                retval = true
            }
        }
        
        if (Thread.current.isMainThread) {
            work()
            return retval
        } else {
            DispatchQueue.main.sync(execute: {
                work()
            })
            return retval
        }
    }
    
    // CBPeripheralManagerDelegate
    
    open func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        NSLog("Bluetooth status: ")
        switch (self.bluetoothPeripheralManager.state) {
        case .unknown:
            NSLog("Unknown")
            self.bluetoothState = .unknown
        case .resetting:
            NSLog("Resetting")
            self.bluetoothState = .other
        case .unsupported:
            NSLog("Unsupported")
            self.bluetoothState = .other
        case .unauthorized:
            NSLog("Unauthorized")
            self.bluetoothState = .other
        case .poweredOff:
            NSLog("PoweredOff")
            self.bluetoothState = .poweredOff
        case .poweredOn:
            NSLog("PoweredOn")
            self.bluetoothState = .poweredOn
        }
        self.bluetoothBlock?(self.bluetoothState)
    }
    
    func dispatch_on_delegate_queue(_ block: @escaping ()->()) {
        if let queue = self.delegateQueue {
            queue.async(execute: block)
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }

}
