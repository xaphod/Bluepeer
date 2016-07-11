//
//  MultipeerObject.swift
//  BluePrint
//
//  Created by Tim Carr on 6/23/16.
//  Copyright © 2016 Tim Carr. All rights reserved.
//

import Foundation
import MultipeerConnectivity
import Fabric
import Crashlytics
import CoreBluetooth

@objc public protocol MultipeerSessionManagerDelegate {
    optional func peerDidConnect(session: MCSession?, peerRole: RoleType, peer: MCPeerID)
    optional func peerDidDisconnect(session: MCSession?, peerRole: RoleType, peer: MCPeerID)
    optional func peerConnectionAttemptFailed(session: MCSession?, peerRole: RoleType, peer: MCPeerID)
    optional func sessionConnectionRequest(session: MCSession, peer: MCPeerID, context: NSData?, invitationHandler: (Bool, MCSession) -> Void)
    optional func browserFoundPeer(role: RoleType, peer: MCPeerID, discoveryInfo: [String : String]?, inviteBlock: (timeoutForInvite: NSTimeInterval) -> Void)
}

@objc public protocol MultipeerDataDelegate {
    func didReceiveData(data: NSData, fromPeer peerID: MCPeerID)
    optional func failedToStartAdvertising(error: NSError)
    optional func failedToStartBrowsing(error: NSError)
}

@objc public class MultipeerObject: NSObject, MCNearbyServiceAdvertiserDelegate, MCSessionDelegate, MCBrowserViewControllerDelegate, CBPeripheralManagerDelegate, MCNearbyServiceBrowserDelegate {
    
    var delegateQueue: dispatch_queue_t?
    public var serviceType: String
    var myID: MCPeerID
    var versionString: String = "unknown"
    var advertiser: MCNearbyServiceAdvertiser?
    var browser: MCNearbyServiceBrowser?
    var activeSession: MCSession
    weak public var sessionDelegate: MultipeerSessionManagerDelegate?
    weak public var dataDelegate: MultipeerDataDelegate?
    public var peers: [MCPeerID:(role: RoleType, state: MCSessionState)]? = [:]
    public var bluetoothState : BluetoothState = .Unknown
    var browserCompletionBlock: ((success: Bool) -> Void)?
    var bluetoothPeripheralManager: CBPeripheralManager
    public var bluetoothBlock: ((bluetoothState: BluetoothState) -> Void)?
    public var disconnectOnWillResignActive: Bool = false {
        didSet {
            if disconnectOnWillResignActive {
                NSNotificationCenter.defaultCenter().addObserver(self, selector: #selector(willResignActive), name: UIApplicationWillResignActiveNotification, object: nil)
            } else {
                NSNotificationCenter.defaultCenter().removeObserver(self, name: UIApplicationWillResignActiveNotification, object: nil)
            }
        }
    }
    
    // if queue isn't given, main queue is used
    public init(serviceType: String, displayName:String?, encryptionPreference: MCEncryptionPreference, queue:dispatch_queue_t?, bluetoothBlock: ((bluetoothState: BluetoothState)->Void)?) { // serviceType must be 1-15 chars, only a-z0-9 and hyphen, eg "xd-blueprint"
        Fabric.with([Crashlytics.self, Answers.self])
        self.serviceType = serviceType
        self.delegateQueue = queue
        self.bluetoothPeripheralManager = CBPeripheralManager.init(delegate: nil, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey:0])
        if let name = displayName {
            myID = MCPeerID.init(displayName: name)
        } else {
            myID = MCPeerID.init(displayName: UIDevice.currentDevice().name)
        }
        
        if let bundleVersionString = NSBundle.mainBundle().infoDictionary?["CFBundleVersion"] as? String {
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
        NSNotificationCenter.defaultCenter().removeObserver(self)
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

    public func disconnectSession() {
        self.activeSession.disconnect()
    }
    
    public func connectedRoleCount(role: RoleType) -> Int {
        guard let _ = self.peers else {
            return 0
        }
        return self.peers!.filter({ $0.1.role == role && $0.1.state == .Connected }).count
    }
    
    public func startAdvertising(role: RoleType) {
        advertiser = MCNearbyServiceAdvertiser.init(peer: myID, discoveryInfo: ["version":versionString, "role":(role == .Server ? "Server" : "Client")], serviceType: serviceType)
        advertiser?.delegate = self;
        advertiser?.startAdvertisingPeer()
        NSLog("Multipeer: now advertising as role \(role == .Server ? "Server" : "Client") for service \(serviceType)")
    }
    
    public func stopAdvertising() {
        if let advertiser = self.advertiser {
            advertiser.stopAdvertisingPeer()
            advertiser.delegate = nil
            self.advertiser = nil
            NSLog("Multipeer: advertising stopped")
        }
    }
    
    public func startBrowsing() {
        self.browser = MCNearbyServiceBrowser.init(peer: myID, serviceType: serviceType)
        self.browser?.delegate = self
        self.browser?.startBrowsingForPeers()
        NSLog("Multipeer: now browsing for service \(serviceType)")
    }
    
    public func stopBrowsing() {
        self.browser?.stopBrowsingForPeers()
        self.browser?.delegate = nil
        self.browser = nil
    }
    
    
    // If specified, peers takes precedence.
    public func sendData(datas: [NSData]!, toPeers:[MCPeerID]?, toRole: RoleType) throws {
        if let peers = self.peers {
            var targetPeers: [MCPeerID]
            if let toPeers = toPeers {
                targetPeers = toPeers
            } else {
                let peersArray: [(MCPeerID, (role: RoleType, state: MCSessionState))] = peers.filter({
                    if toRole != .All {
                        return $0.1.role == toRole && $0.1.state == .Connected
                    } else {
                        return $0.1.state == .Connected
                    }
                })
                targetPeers = peersArray.map({$0.0})
            }
            
            for data in datas {
                NSLog("Multipeer sending to %d peers", targetPeers.count)
                try self.activeSession.sendData(data, toPeers: targetPeers, withMode: .Reliable)
            }
        }
    }
    
    func registerPeer(peerID: MCPeerID, info: [String : String]?) -> RoleType {
        var retval = RoleType.Unknown
        if let info = info {
            if let role = info["role"] {
                // save roles for later!
                if let _ = self.peers {
                    switch role {
                    case "Server":
                        retval = .Server
                        NSLog("Multipeer Browser found a server: \(peerID.displayName)")
                    case "Client":
                        retval = .Client
                        NSLog("Multipeer Browser found a client: \(peerID.displayName)")
                    default:
                        retval = .Client
                        NSLog("Multipeer Browser found unknown type, presuming client!!!: \(peerID.displayName)")
                    }
                    
                    self.peers!.updateValue((retval, .NotConnected), forKey: peerID)
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
    
    public func getBrowser(browserCompletionBlock: ((success: Bool) -> Void)?) -> MCBrowserViewController? {
        self.browserCompletionBlock = browserCompletionBlock
        let browserViewController = MCBrowserViewController.init(serviceType: self.serviceType, session: self.activeSession)
        browserViewController.delegate = self
        return browserViewController
    }
    
    // MCNearbyServiceBrowserDelegate
    public func browser(browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) {
        let role = self.registerPeer(peerID, info: info)
        
        if let delegate = self.sessionDelegate {
            self.dispatch_on_delegate_queue({
                delegate.browserFoundPeer?(role, peer: peerID, discoveryInfo: info, inviteBlock: { (timeoutForInvite) in
                    browser.invitePeer(peerID, toSession: self.activeSession, withContext: nil, timeout: timeoutForInvite)
                })
            })
        }
    }
    
    public func browser(browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        NSLog("Multipeer lost peer: \(peerID.displayName)")
        if var peers = self.peers {
            if let oldVal = peers[peerID] {
                peers.updateValue((oldVal.role, .NotConnected), forKey: peerID)
            }
        }
    }
    
    public func browser(browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: NSError) {
        NSLog("Multipeer browser failed to start: \(error)")
        if let delegate = self.dataDelegate {
            self.dispatch_on_delegate_queue({
                delegate.failedToStartBrowsing?(error)
            })
        }
    }

    
    // MCNearbyServiceAdvertiserDelegate
    
    public func advertiser(advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: NSError) {
        NSLog("ERROR: could not start advertising. Error: \(error)")
        if let delegate = self.dataDelegate {
            self.dispatch_on_delegate_queue({
                delegate.failedToStartAdvertising?(error)
            })
        }
    }
    
    public func advertiser(advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: NSData?, invitationHandler: (Bool, MCSession) -> Void) {
        NSLog("Invitation received from peer \(peerID.displayName)")
        
        if let delegate = self.sessionDelegate {
            self.dispatch_on_delegate_queue({
                delegate.sessionConnectionRequest?(self.activeSession, peer: peerID, context: context, invitationHandler: invitationHandler)
            })
        }
    }
    
    
    // MCSessionDelegate
    
    public func session(session: MCSession, didReceiveData data: NSData, fromPeer peerID: MCPeerID) {
        // TODO: BUG - when two clients print at same time, their data gets mixed up together somehow
        NSLog("\(#function) - peer: \(peerID.displayName)")
        if let delegate = self.dataDelegate {
            self.dispatch_on_delegate_queue({
                delegate.didReceiveData(data, fromPeer: peerID)
            })
        }
    }
    
    public func session(session: MCSession, peer peerID: MCPeerID, didChangeState state: MCSessionState) {
        self.dispatch_on_delegate_queue({
            let stateString = state == .Connected ? "Connected" : (state == .Connecting ? "Connecting" : "Not connected")
            NSLog("\(#function) - peer: \(peerID.displayName), state: \(stateString)")
            
            if (state == .Connected) {
                if self.peers![peerID] == nil {
                    // if we are connected, and it's not in the dict, then we are a server, so it is a client
                    NSLog("Adding new connected peer \(peerID.displayName), assuming it is a CLIENT")
                    self.peers![peerID] = (.Client, .Connected)
                } else {
                    NSLog("Marking existing peer \(peerID.displayName) as connected. Role = \((self.peers![peerID]!.role == .Server ? "Server" : "Client"))")
                    self.peers![peerID]?.state = .Connected
                }
                
                if let delegate = self.sessionDelegate {
                    delegate.peerDidConnect?(session, peerRole: self.peers![peerID]!.role, peer: peerID)
                }
            } else if (state == .NotConnected) {
                
                if self.peers![peerID] != nil {
                    let oldState = self.peers![peerID]!.state
                    let role = self.peers![peerID]!.role
                    if (oldState == .Connected) {
                        self.peers![peerID] = nil
                        if let delegate = self.sessionDelegate {
                            delegate.peerDidDisconnect?(session, peerRole: role, peer: peerID)
                        }
                    } else {
                        self.peers![peerID]!.state = state
                        if (oldState == .Connecting) {
                            if let delegate = self.sessionDelegate {
                                delegate.peerConnectionAttemptFailed?(session, peerRole: role, peer: peerID)
                            }
                        }
                    }
                }
            } else if (state == .Connecting) {
                self.peers![peerID]?.state = .Connecting
            }
        })
    }
    
    public func session(session: MCSession, didReceiveStream stream: NSInputStream, withName streamName: String, fromPeer peerID: MCPeerID) {
        NSLog("\(#function) - peer: \(peerID.displayName)")
    }
    
    public func session(session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, withProgress progress: NSProgress) {
        NSLog("\(#function) - peer: \(peerID.displayName)")
    }
    
    public func session(session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, atURL localURL: NSURL, withError error: NSError?) {
        NSLog("\(#function) - peer: \(peerID.displayName)")
    }
    
    
    // MCBrowserViewControllerDelegate
    public func browserViewControllerDidFinish(browserViewController: MCBrowserViewController) {
        if let completionBlock = self.browserCompletionBlock {
            dispatch_async(dispatch_get_main_queue(), {
                completionBlock(success: true)
                self.browserCompletionBlock = nil
            })
        }
    }
    
    public func browserViewControllerWasCancelled(browserViewController: MCBrowserViewController) {
        if let completionBlock = self.browserCompletionBlock {
            dispatch_async(dispatch_get_main_queue(), {
                completionBlock(success: false)
                self.browserCompletionBlock = nil
            })
        }
    }
    
    public func browserViewController(browserViewController: MCBrowserViewController, shouldPresentNearbyPeer peerID: MCPeerID, withDiscoveryInfo info: [String : String]?) -> Bool {
        
        var retval = false
        
        let work = {
            let role = self.registerPeer(peerID, info: info)
            if (role == .Server) {
                retval = true
            }
        }
        
        if (NSThread.currentThread().isMainThread) {
            work()
            return retval
        } else {
            dispatch_sync(dispatch_get_main_queue(), {
                work()
            })
            return retval
        }
    }
    
    // CBPeripheralManagerDelegate
    
    public func peripheralManagerDidUpdateState(peripheral: CBPeripheralManager) {
        NSLog("Bluetooth status: ")
        switch (self.bluetoothPeripheralManager.state) {
        case .Unknown:
            NSLog("Unknown")
            self.bluetoothState = .Unknown
        case .Resetting:
            NSLog("Resetting")
            self.bluetoothState = .Other
        case .Unsupported:
            NSLog("Unsupported")
            self.bluetoothState = .Other
        case .Unauthorized:
            NSLog("Unauthorized")
            self.bluetoothState = .Other
        case .PoweredOff:
            NSLog("PoweredOff")
            self.bluetoothState = .PoweredOff
        case .PoweredOn:
            NSLog("PoweredOn")
            self.bluetoothState = .PoweredOn
        }
        self.bluetoothBlock?(bluetoothState: self.bluetoothState)
    }
    
    func dispatch_on_delegate_queue(block: dispatch_block_t) {
        if let queue = self.delegateQueue {
            dispatch_async(queue, block)
        } else {
            dispatch_async(dispatch_get_main_queue(), block)
        }
    }

}
