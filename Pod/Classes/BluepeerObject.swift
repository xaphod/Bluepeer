//
//  BluepeerObject.swift
//
//  Created by Tim Carr on 7/7/16.
//  Copyright © 2016 Tim Carr Photo. All rights reserved.
//

import Foundation
import CoreBluetooth
import CFNetwork
import CocoaAsyncSocket // NOTE: requires pod CocoaAsyncSocket
import HHServices
import dnssd

let kDNSServiceInterfaceIndexP2PSwift = UInt32.max-2 // TODO: ARGH THIS IS A SHITTY HACK! I HATE SWIFT TODAY!

@objc public enum RoleType: Int, CustomStringConvertible {
    case unknown = 0
    case server = 1
    case client = 2
    case all = 3
    
    public var description: String {
        switch self {
        case .server: return "Server"
        case .client: return "Client"
        case .unknown: return "Unknown"
        case .all: return "All"
        }
    }
    
    public static func roleFromString(_ roleStr: String?) -> RoleType {
        guard let roleStr = roleStr else {
            return .unknown
        }
        switch roleStr {
            case "Server": return .server
            case "Client": return .client
            case "Unknown": return .unknown
            case "All": return .all
        default: return .unknown
        }
    }
}

@objc public enum BluetoothState: Int {
    case unknown = 0
    case poweredOff = 1
    case poweredOn = 2
    case other = 3
}


@objc public enum BPPeerState: Int, CustomStringConvertible {
    case notConnected = 0
    case connecting = 1
    case awaitingAuth = 2
    case connected = 3
    
    public var description: String {
        switch self {
        case .notConnected: return "NotConnected"
        case .connecting: return "Connecting"
        case .connected: return "Connected"
        case .awaitingAuth: return "AwaitingAuth"
        }
    }
}

@objc open class BPPeer: NSObject {
    open var displayName: String = "" // is HHService.name !
    open var socket: GCDAsyncSocket?
    open var role: RoleType = .unknown
    open var state: BPPeerState = .notConnected
    var dnsService: HHService?
    var announced = false
    open var keepaliveTimer: Timer?
    open var lastReceivedData: Date = Date.init(timeIntervalSince1970: 0)
}

@objc public protocol BluepeerSessionManagerDelegate {
    @objc optional func peerDidConnect(_ peerRole: RoleType, peer: BPPeer)
    @objc optional func peerDidDisconnect(_ peerRole: RoleType, peer: BPPeer)
    @objc optional func peerConnectionAttemptFailed(_ peerRole: RoleType, peer: BPPeer?, isAuthRejection: Bool)
    @objc optional func peerConnectionRequest(_ peer: BPPeer, invitationHandler: @escaping (Bool) -> Void) // was named: sessionConnectionRequest
    @objc optional func browserFoundPeer(_ role: RoleType, peer: BPPeer, inviteBlock: @escaping (_ timeoutForInvite: TimeInterval) -> Void)
    @objc optional func browserLostPeer(_ role: RoleType, peer: BPPeer)
}

@objc public protocol BluepeerDataDelegate {
    func didReceiveData(_ data: Data, fromPeer peerID: BPPeer)
}

@objc public protocol BluepeerLoggingDelegate {
    func didReadWrite(_ logString: String)
}

/* ADD TO POD FILE
 post_install do |installer_representation|
   installer_representation.pods_project.targets.each do |target|
     target.build_configurations.each do |config|
       if config.name != 'Release'
         config.build_settings['GCC_PREPROCESSOR_DEFINITIONS'] ||= ['$(inherited)', 'DEBUG=1']
         config.build_settings['OTHER_SWIFT_FLAGS'] = ['$(inherited)', '-DDEBUG']
       end
     end
   end
 end
*/

func DLog(_ items: Any...) {
    #if DEBUG
        debugPrint(items)
    #endif
}



@objc open class BluepeerObject: NSObject {
    
    var delegateQueue: DispatchQueue?
    var serverSocket: GCDAsyncSocket?
    var publisher: HHServicePublisher?
    var browser: HHServiceBrowser?
    var bluetoothOnly: Bool = false
    open var advertising: RoleType?
    open var browsing: Bool = false
    var onLastBackground: (advertising: RoleType?, browsing: Bool) = (nil, false)
    open var serviceType: String
    var serverPort: UInt16 = 0
    var versionString: String = "unknown"
    var displayName: String = UIDevice.current.name
    var sanitizedDisplayName: String {
        // sanitize name
        var retval = self.displayName.lowercased()
        if retval.characters.count > 15 {
            retval = retval.substring(to: retval.characters.index(retval.startIndex, offsetBy: 15))
        }
        let acceptableChars = CharacterSet.init(charactersIn: "abcdefghijklmnopqrstuvwxyz1234567890-")
        retval = String(retval.characters.map { (char: Character) in
            if acceptableChars.containsCharacter(char) == false {
                return "-"
            } else {
                return char
            }
        })
        return retval
    }
    
    weak open var sessionDelegate: BluepeerSessionManagerDelegate?
    weak open var dataDelegate: BluepeerDataDelegate?
    weak open var logDelegate: BluepeerLoggingDelegate?
    open var peers = [BPPeer]()
    open var bluetoothState : BluetoothState = .unknown
    var bluetoothPeripheralManager: CBPeripheralManager!
    open var bluetoothBlock: ((_ bluetoothState: BluetoothState) -> Void)?
    open var disconnectOnBackground: Bool = false
    let headerTerminator: Data = "\r\n\r\n".data(using: String.Encoding.utf8)! // same as HTTP. But header content here is just a number, representing the byte count of the incoming nsdata.
    let keepAliveHeader: Data = "0 ! 0 ! 0 ! 0 ! 0 ! 0 ! 0 ! ".data(using: String.Encoding.utf8)! // A special header kept to avoid timeouts
    let socketQueue = DispatchQueue(label: "xaphod.bluepeer.socketQueue", attributes: [])
    var browsingWorkaroundRestarts = 0
    var backgroundTask: UIBackgroundTaskIdentifier?
    
    enum DataTag: Int {
        case tag_HEADER = 1
        case tag_BODY = 2
        case tag_WRITING = 3
        case tag_AUTH = 4
        case tag_NAME = 5
    }
    
    enum Timeouts: Double {
        case header = 40
        case body = 90
        case keepAlive = 30
    }
    
    // if queue isn't given, main queue is used
    public init(serviceType: String, displayName:String?, queue:DispatchQueue?, serverPort: UInt16, overBluetoothOnly:Bool, bluetoothBlock: ((_ bluetoothState: BluetoothState)->Void)?) { // serviceType must be 1-15 chars, only a-z0-9 and hyphen, eg "xd-blueprint"
        self.serverPort = serverPort
        self.serviceType = "_" + serviceType + "._tcp"
        self.bluetoothOnly = overBluetoothOnly
        self.delegateQueue = queue
        
        super.init()

        if let name = displayName {
            self.displayName = name.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
        }

        if let bundleVersionString = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            versionString = bundleVersionString
        }

        self.bluetoothBlock = bluetoothBlock
        self.bluetoothPeripheralManager = CBPeripheralManager.init(delegate: self, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey:0])
        NotificationCenter.default.addObserver(self, selector: #selector(didEnterBackground), name: NSNotification.Name.UIApplicationDidEnterBackground, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(willEnterForeground), name: NSNotification.Name.UIApplicationWillEnterForeground, object: nil)
        DLog("Initialized BluepeerObject. Name: \(self.displayName), bluetoothOnly: \(self.bluetoothOnly ? "yes" : "no")")
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
        self.killAllKeepaliveTimers() // probably moot: won't start deiniting until all timers are dead, because they have a strong ref to self
        self.disconnectSession()
        self.stopBrowsing()
        self.stopAdvertising()
        DLog("BluepeerObject: DEINIT FINISH")
        self.endBackgroundTask()
    }
    
    // Note: if I disconnect, then my delegate is expected to reconnect if needed.
    func didEnterBackground() {
        self.backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "BluepeerBackgroundedTask", expirationHandler: {
            self.endBackgroundTask()
        })
        self.onLastBackground = (self.advertising, self.browsing)
        stopBrowsing()
        stopAdvertising()
        if disconnectOnBackground {
            disconnectSession()
            DLog("BluepeerObject: didEnterBackground - stopped browsing & advertising, and disconnected session")
        } else {
            DLog("BluepeerObject: didEnterBackground - stopped browsing & advertising")
            self.endBackgroundTask()
        }
    }
    
    func endBackgroundTask() {
        if let backgroundTask = self.backgroundTask {
            UIApplication.shared.endBackgroundTask(backgroundTask)
        }
        self.backgroundTask = UIBackgroundTaskInvalid
    }
    
    func willEnterForeground() {
        if let role = self.onLastBackground.advertising {
            startAdvertising(role)
        }
        if self.onLastBackground.browsing {
            startBrowsing()
        }
    }
    
    open func disconnectSession() {
        // don't close serverSocket: expectation is that only stopAdvertising does this
        // loop through peers, disconenct all sockets
        for peer in self.peers {
            DLog("BluepeerObject disconnectSession: disconnecting \(peer.displayName)")
            peer.socket?.synchronouslySetDelegate(nil) // we don't want to run our disconnection logic below
            peer.socket?.disconnect()
            peer.socket = nil
            peer.dnsService?.endResolve()
            peer.dnsService = nil
            peer.state = .notConnected
            peer.announced = false
            peer.keepaliveTimer?.invalidate()
            peer.keepaliveTimer = nil
        }
        self.peers = [] // remove all peers!
    }
    
    open func connectedRoleCount(_ role: RoleType) -> Int {
        return self.peers.filter({ $0.role == role && $0.state == .connected }).count
    }
    
    open func startAdvertising(_ role: RoleType) {
        if let _ = self.advertising {
            DLog("BluepeerObject: Already advertising (no-op)")
            return
        }

        DLog("BluepeerObject: starting advertising using port \(serverPort)")

        // type must be like: _myexampleservice._tcp  (no trailing .)
        // txtData: let's use this for RoleType. For now just shove RoleType in there!
        // txtData, from http://www.zeroconf.org/rendezvous/txtrecords.html: Using TXT records larger than 1300 bytes is NOT RECOMMENDED at this time. The format of the data within a DNS TXT record is zero or more strings, packed together in memory without any intervening gaps or padding bytes for word alignment. The format of each constituent string within the DNS TXT record is a single length byte, followed by 0-255 bytes of text data.
    
        // Could use the NSNetService version of this (TXTDATA maker), it'd be easier :)
        let swiftdict = ["role":"Server"] // assume I am a Server if I am told to start advertising
        let cfdata: Unmanaged<CFData>? = CFNetServiceCreateTXTDataWithDictionary(kCFAllocatorDefault, swiftdict as CFDictionary)
        let txtdata = cfdata?.takeUnretainedValue()
        guard let _ = txtdata else {
            DLog("BluepeerObject: ERROR could not create TXTDATA nsdata")
            return
        }
        self.publisher = HHServicePublisher.init(name: self.sanitizedDisplayName, type: self.serviceType, domain: "local.", txtData: txtdata as Data!, port: UInt(serverPort))
        
        guard let publisher = self.publisher else {
            DLog("BluepeerObject: could not create publisher")
            return
        }
        publisher.delegate = self
        var starting: Bool
        if (self.bluetoothOnly) {
            starting = publisher.beginPublishOverBluetoothOnly()
        } else {
            starting = publisher.beginPublish()
        }
        if !starting {
            DLog("BluepeerObject ERROR: could not start advertising")
            self.publisher = nil
        }
        // serverSocket is created in didPublish delegate (from HHServicePublisherDelegate) below
        self.advertising = role
    }
    
    open func stopAdvertising() {
        if let _ = self.advertising {
            guard let publisher = self.publisher else {
                DLog("BluepeerObject: publisher is MIA while advertising set true! ERROR. Setting advertising=false")
                self.advertising = nil
                return
            }
            publisher.endPublish()
            DLog("BluepeerObject: advertising stopped")
        } else {
            DLog("BluepeerObject: no advertising to stop (no-op)")
        }
        self.publisher = nil
        self.advertising = nil
        if let socket = self.serverSocket {
            socket.synchronouslySetDelegate(nil)
            socket.disconnect()
            self.serverSocket = nil
            DLog("BluepeerObject: destroyed serverSocket")
        }
    }
    
    open func startBrowsing() {
        if self.browsing == true {
            DLog("BluepeerObject: Already browsing (no-op)")
            return
        }

        self.browser = HHServiceBrowser.init(type: self.serviceType, domain: "local.")
        guard let browser = self.browser else {
            DLog("BluepeerObject: ERROR, could not create browser")
            return
        }
        browser.delegate = self
        if (self.bluetoothOnly) {
            self.browsing = browser.beginBrowseOverBluetoothOnly()
        } else {
            self.browsing = browser.beginBrowse()
        }
        DLog("BluepeerObject: now browsing")
    }
    
    open func stopBrowsing() {
        if (self.browsing) {
            if self.browser == nil {
                DLog("BluepeerObject: WARNING, browser is MIA while browsing set true! ")
            } else {
                self.browser!.endBrowse()
                DLog("BluepeerObject: browsing stopped")
            }
        } else {
            DLog("BluepeerObject: no browsing to stop")
        }
        self.browser = nil
        self.browsing = false
        for peer in self.peers {
            peer.dnsService?.endResolve()
            peer.dnsService = nil
            peer.announced = false
        }
    }
    
    open func sendData(_ datas: [Data], toPeers:[BPPeer]) throws {
        for data in datas {
            DLog("BluepeerObject: sending data size \(data.count) to \(toPeers.count) peers")
            for peer in toPeers {
                self.logDelegate?.didReadWrite("writeSendDataToPeers")
                self.sendDataInternal(peer, data: data)
            }
        }
    }
    
    open func sendData(_ datas: [Data], toRole: RoleType) throws {
        let targetPeers: [BPPeer] = peers.filter({
            if toRole != .all {
                return $0.role == toRole && $0.state == .connected
            } else {
                return $0.state == .connected
            }
        })
    
        for data in datas {
            if data.count == 0 {
                continue
            }
            DLog("BluepeerObject sending data size \(data.count) to \(targetPeers.count) peers")
            for peer in targetPeers {
                self.logDelegate?.didReadWrite("writeSendDataToRole")
                self.sendDataInternal(peer, data: data)
            }
        }
    }

    func sendDataInternal(_ peer: BPPeer, data: Data) {
        // send header first. Then separator. Then send body.
        // length: send as 4-byte, then 4 bytes of unused 0s for now. assumes endianness doesn't change between platforms, ie 23 00 00 00 not 00 00 00 23
        var length: UInt = UInt(data.count)
        let senddata = NSMutableData.init(bytes: &length, length: 4)
        let unused4bytesdata = NSMutableData.init(length: 4)!
        senddata.append(unused4bytesdata as Data)
        senddata.append(self.headerTerminator)
        senddata.append(data)
        
//        DLog("sendDataInternal writes: \((senddata as Data).hex), payload part: \(data.hex)")
        peer.socket?.write(senddata as Data, withTimeout: Timeouts.body.rawValue, tag: DataTag.tag_WRITING.rawValue)
    }
    
    func scheduleNextKeepaliveTimer(_ peer: BPPeer) {
        DispatchQueue.main.async(execute: { // timer needs main, don't want to do checks earlier than right before scheduling timer
            if peer.state != .connected || peer.socket == nil {
                return
            }

            peer.lastReceivedData = Date.init()

            if peer.keepaliveTimer?.isValid == true {
                return
            }

            let delay: TimeInterval = Timeouts.keepAlive.rawValue - 5 - (Double(arc4random_uniform(5000)) / Double(1000)) // keepAlive.rawValue - 5 - (up to 5)
            DLog("BluepeerObject: keepalive INITIAL SCHEDULING for \(peer.displayName) in \(delay)s")
            peer.keepaliveTimer = Timer.scheduledTimer(timeInterval: delay, target: self, selector: #selector(self.keepAliveTimerFired), userInfo: ["peer":peer], repeats: true)
        })
    }
    
    func keepAliveTimerFired(_ timer: Timer) {
        guard let ui = timer.userInfo as? Dictionary<String, AnyObject> else {
            assert(false, "ERROR")
            timer.invalidate()
            return
        }
        guard let peer = ui["peer"] as? BPPeer else {
            DLog("BluepeerObject: keepAlive timer didn't find a peer, invalidating timer")
            timer.invalidate()
            return
        }
        if peer.state != .connected || peer.socket == nil {
            DLog("BluepeerObject: keepAlive timer finds peer isn't connected, invalidating timer")
            timer.invalidate()
            peer.keepaliveTimer = nil
        } else {
            var senddata = NSData.init(data: self.keepAliveHeader) as Data
            senddata.append(self.headerTerminator)
            self.logDelegate?.didReadWrite("writeKeepAlive")
            
//            DLog("keepAlivetimer writes: \(senddata.hex)")
            
            peer.socket?.write(senddata, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_WRITING.rawValue)
            DLog("BluepeerObject: send keepAlive to \(peer.displayName) @ \(peer.socket?.connectedHost)")
        }
    }
    
    func killAllKeepaliveTimers() {
        for peer in self.peers {
            peer.keepaliveTimer?.invalidate()
            peer.keepaliveTimer = nil
        }
    }
    
    func dispatch_on_delegate_queue(_ block: @escaping ()->()) {
        if let queue = self.delegateQueue {
            queue.async(execute: block)
        } else {
            DispatchQueue.main.async(execute: block)
        }
    }
    
    open func getBrowser(_ completionBlock: @escaping (Bool) -> ()) -> UIViewController? {
        let initialVC = self.getStoryboard()?.instantiateInitialViewController()
        var browserVC = initialVC
        if let nav = browserVC as? UINavigationController {
            browserVC = nav.topViewController
        }
        guard let browser = browserVC as? BluepeerBrowserViewController else {
            assert(false, "ERROR - storyboard layout changed")
            return nil
        }
        browser.bluepeerObject = self
        browser.browserCompletionBlock = completionBlock
        return initialVC
    }
    
    func getStoryboard() -> UIStoryboard? {
        guard let bundlePath = Bundle.init(for: BluepeerObject.self).path(forResource: "Bluepeer", ofType: "bundle") else {
            assert(false, "ERROR: could not load bundle")
            return nil
        }
        return UIStoryboard.init(name: "Bluepeer", bundle: Bundle.init(path: bundlePath))
    }
}

extension GCDAsyncSocket {
    var peer: BPPeer? {
        guard let bo = self.delegate as? BluepeerObject else {
            return nil
        }
        guard let peer = bo.peers.filter({ $0.socket == self }).first else {
            return nil
        }
        return peer
    }
}

extension BluepeerObject : HHServicePublisherDelegate {
    public func serviceDidPublish(_ servicePublisher: HHServicePublisher) {
        // create serverSocket
        if let socket = self.serverSocket {
            socket.synchronouslySetDelegate(nil)
            socket.disconnect()
            self.serverSocket = nil
        }
        
        self.serverSocket = GCDAsyncSocket.init(delegate: self, delegateQueue: socketQueue)
        self.serverSocket?.isIPv4PreferredOverIPv6 = false
        guard let serverSocket = self.serverSocket else {
            DLog("BluepeerObject: ERROR - Could not create serverSocket")
            return
        }
        
        do {
            try serverSocket.accept(onPort: serverPort)
        } catch {
            DLog("BluepeerObject: ERROR accepting on serverSocket")
            return
        }
        
        DLog("BluepeerObject: now advertising for service \(serviceType)")
    }
    
    public func serviceDidNotPublish(_ servicePublisher: HHServicePublisher) {
        self.advertising = nil
        DLog("BluepeerObject: ERROR: serviceDidNotPublish")
    }
}

extension BluepeerObject : HHServiceBrowserDelegate {
    public func serviceBrowser(_ serviceBrowser: HHServiceBrowser, didFind service: HHService, moreComing: Bool) {
        DLog("BluepeerObject: didFindService \(service.name), moreComing: \(moreComing)")
        if self.browsing == false {
            return
        }
        if service.type == self.serviceType {
            service.delegate = self
            
            // if this peer eixsts, then add this as another address(es), otherwise add now
            var peer = self.peers.filter({ $0.displayName == service.name }).first
            
            if peer == nil {
                peer = BPPeer.init()
                guard let peer = peer else { return }
                peer.displayName = service.name
                peer.dnsService = service
                self.peers.append(peer)
                DLog("BluepeerObject didFind: created new peer \(peer.displayName). Peers.count after adding: \(self.peers.count)")
            } else {
                DLog("BluepeerObject didFind: found existing peer \(peer?.displayName), replacing with newer service")
                peer?.dnsService?.endResolve()
                peer?.dnsService = service
            }

            let prots = UInt32(kDNSServiceProtocol_IPv4) | UInt32(kDNSServiceProtocol_IPv6)
            if (self.bluetoothOnly) {
                service.beginResolve(kDNSServiceInterfaceIndexP2PSwift, includeP2P: true, addressLookupProtocols: prots)
            } else {
                service.beginResolve(UInt32(kDNSServiceInterfaceIndexAny), includeP2P: true, addressLookupProtocols: prots)
            }
        }
    }
    
    public func serviceBrowser(_ serviceBrowser: HHServiceBrowser, didRemove service: HHService, moreComing: Bool) {
        DLog("BluepeerObject: didRemoveService \(service.name) -- IGNORING")
//        DLog("BluepeerObject: didRemoveService \(service.name)")
//        if let peer = self.peers.filter({ $0.dnsService == service }).first {
//            peer.dnsService?.endResolve()
//            peer.dnsService = nil
//            peer.announced = false
//            self.dispatch_on_delegate_queue({
//                self.sessionDelegate?.browserLostPeer?(peer.role, peer: peer)
//            })
//        }
    }
}

extension BluepeerObject : HHServiceDelegate {
    public func serviceDidResolve(_ service: HHService, moreComing: Bool) {
        if self.browsing == false {
            return
        }
        
        guard let delegate = self.sessionDelegate else {
            DLog("BluepeerObject: WARNING, ignoring resolved service because sessionDelegate is not set")
            return
        }
        guard let txtdata = service.txtData else {
            DLog("BluepeerObject: serviceDidResolve IGNORING service because no txtData found")
            return
        }
        
        let cfdict: Unmanaged<CFDictionary>? = CFNetServiceCreateDictionaryWithTXTData(kCFAllocatorDefault, txtdata as CFData)
        guard let _ = cfdict else {
            DLog("BluepeerObject: serviceDidResolve IGNORING service because txtData was invalid")
            return
        }
        let dict: NSDictionary = cfdict!.takeUnretainedValue()
        guard let roleData = dict["role"] as? Data else {
            DLog("BluepeerObject: serviceDidResolve IGNORING service because role was missing")
            return
        }
        let roleStr = String.init(data: roleData, encoding: String.Encoding.utf8)
        let role = RoleType.roleFromString(roleStr)
        if role == .unknown {
            assert(false, "Expecting a role that isn't unknown here")
            return
        }
        guard let peer = self.peers.filter({ $0.dnsService == service }).first else {
            DLog("BluepeerObject: serviceDidResolve FAILED, should have found a peer")
            assert(false)
            return
        }
        guard let hhaddresses: [HHAddressInfo] = service.resolvedAddressInfo, hhaddresses.count > 0 else {
            DLog("BluepeerObject: serviceDidResolve IGNORING service because could not get resolvedAddressInfo")
            return
        }
        
        peer.role = role
        DLog("BluepeerObject: serviceDidResolve, name: \(service.name), role: \(roleStr), announced: \(peer.announced), addresses: \(hhaddresses.count)")
        
        // should we annouce? if we have at least one candidate address, yes.
        var limitToBluetooth = self.bluetoothOnly
        let candidates = hhaddresses.filter({ $0.isCandidateAddress(bluetoothOnly: limitToBluetooth) })
        if peer.announced {
            DLog("... already announced, not continuing")
            return
        } else if candidates.count == 0 {
            DLog("... no candidates out of \(hhaddresses.count) addresses, not announcing. moreComing = \(moreComing)")
            if hhaddresses.count > 1 && !moreComing {
                if (self.browsingWorkaroundRestarts >= 3) {
                    DLog(" *** workarounds exhausted! falling back to not bluetoothOnly")
                    self.browsingWorkaroundRestarts = 0
                    limitToBluetooth = false
                    let secondaryCandidates = hhaddresses.filter({ $0.isCandidateAddress(bluetoothOnly: limitToBluetooth) })
                    if (secondaryCandidates.count > 0) {
                        DLog("... announcing now")
                        peer.announced = true
                    } else {
                        DLog("... STILL no candidates. Bummer.")
                        return
                    }
                    
                } else {
                    self.browsingWorkaroundRestarts += 1
                    DLog(" *** workaround for BT radio connection delay: restarting browsing, \(self.browsingWorkaroundRestarts) of 3")
                    self.stopBrowsing()
                    if let indexOfPeer = self.peers.index(of: peer) {
                        self.peers.remove(at: indexOfPeer)
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.startBrowsing()
                    }
                    return
                }
            } else {
                return
            }
        } else {
            DLog("... announcing now")
            peer.announced = true
        }
        
        self.dispatch_on_delegate_queue({
            delegate.browserFoundPeer?(role, peer: peer, inviteBlock: { (timeoutForInvite) in
                do {
                    // pick the address to connect to INSIDE the block, because more addresses may have been added between announcement and inviteBlock being executed
                    guard let hhaddresses = peer.dnsService?.resolvedAddressInfo, hhaddresses.count > 0, var chosenAddress = hhaddresses.filter({ $0.isCandidateAddress(bluetoothOnly: limitToBluetooth) }).first else {
                        DLog("BluepeerObject inviteBlock: ERROR, no resolvedAddresses or candidates!?!")
                        assert(false)
                        return
                    }
                    
                    // if we can use wifi, then use wifi if possible
                    if !self.bluetoothOnly && !chosenAddress.isWifiInterface() {
                        let wifiCandidates = hhaddresses.filter({ $0.isCandidateAddress(bluetoothOnly: self.bluetoothOnly) && $0.isWifiInterface() })
                        if wifiCandidates.count > 0 {
                            chosenAddress = wifiCandidates.first!
                        }
                    }
                    
                    DLog("BluepeerObject inviteBlock: peer has \(hhaddresses.count) addresses, chose \(chosenAddress.addressAndPortString) on interface \(chosenAddress.interfaceName)")
                    let sockdata = chosenAddress.socketAsData()
                    
                    self.stopBrowsing() // stop browsing once user has done something. Destroys all HHService except this one!
                    
                    if let oldSocket = peer.socket {
                        DLog("**** BluepeerObject: PEER ALREADY HAD SOCKET, DESTROYING...")
                        oldSocket.synchronouslySetDelegate(nil)
                        oldSocket.disconnect()
                        peer.socket = nil
                    }
                    
                    peer.socket = GCDAsyncSocket.init(delegate: self, delegateQueue: self.socketQueue)
                    peer.socket?.isIPv4PreferredOverIPv6 = false
                    peer.state = .connecting
                    try peer.socket?.connect(toAddress: sockdata, viaInterface: chosenAddress.interfaceName, withTimeout: timeoutForInvite)
                } catch {
                    DLog("BluepeerObject: could not connect.")
                }
            })
        })
    }

    
    public func serviceDidNotResolve(_ service: HHService) {
        DLog("BluepeerObject: ERROR, service did not resolve: \(service.name)")
    }
}

extension HHAddressInfo {
    func isIPV6() -> Bool {
        let socketAddrData = Data.init(bytes: self.address, count: MemoryLayout<sockaddr>.size)
        var storage = sockaddr_storage()
        (socketAddrData as NSData).getBytes(&storage, length: MemoryLayout<sockaddr_storage>.size)
        if Int32(storage.ss_family) == AF_INET6 {
            return true
        } else {
            return false
        }
    }
    
    func isWifiInterface() -> Bool {
        return self.interfaceName == "en0"
    }
    
    func socketAsData() -> Data {
        var socketAddrData = Data.init(bytes: self.address, count: MemoryLayout<sockaddr>.size)
        var storage = sockaddr_storage()
        (socketAddrData as NSData).getBytes(&storage, length: MemoryLayout<sockaddr_storage>.size)
        if Int32(storage.ss_family) == AF_INET6 {
            socketAddrData = Data.init(bytes: self.address, count: MemoryLayout<sockaddr_in6>.size)
        }
        return socketAddrData
    }

    func isCandidateAddress(bluetoothOnly: Bool) -> Bool {
        if bluetoothOnly && self.isWifiInterface() {
            return false
        }
        if ProcessInfo().isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 10, minorVersion: 0, patchVersion: 0)) {
            // iOS 10: *require* IPv6 address!
            return self.isIPV6()
        } else {
            return true
        }
    }
    
    func IP() -> String? {
        let ipAndPort = self.addressAndPortString
        guard let lastColonIndex = ipAndPort.range(of: ":", options: .backwards)?.lowerBound else {
            DLog("ERROR: unexpected return of IP address with port")
            assert(false, "error")
            return nil
        }
        let ip = ipAndPort.substring(to: lastColonIndex)
        if ipAndPort.components(separatedBy: ":").count-1 > 1 {
            // ipv6 - looks like [00:22:22.....]:port
            return ip.substring(with: Range(uncheckedBounds: (lower: ip.index(ip.startIndex, offsetBy: 1), upper: ip.index(ip.endIndex, offsetBy: -1))))
        }
        return ip
    }
}


extension BluepeerObject : GCDAsyncSocketDelegate {
    
    public func socket(_ sock: GCDAsyncSocket, didAcceptNewSocket newSocket: GCDAsyncSocket) {
        
        if self.sessionDelegate != nil {
            guard let connectedHost = newSocket.connectedHost else {
                DLog("BluepeerObject: ERROR, accepted newSocket has no connectedHost (no-op)")
                return
            }
            newSocket.delegate = self
            
            let newPeer = BPPeer.init()
            newPeer.state = .awaitingAuth
            newPeer.role = .client
            newPeer.socket = newSocket
            self.peers.append(newPeer) // always add as a new peer, even if it already exists
            DLog("BluepeerObject: accepting new connection from \(connectedHost). Peers.count after add: \(self.peers.count)")
            
            // CONVENTION: CLIENT sends SERVER 32 bytes of its name -- UTF-8 string
            self.logDelegate?.didReadWrite("readName")
            newSocket.readData(toLength: 32, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_NAME.rawValue)
        } else {
            DLog("BluepeerObject: WARNING, ignoring connection attempt because I don't have a sessionDelegate assigned")
        }
    }
    
    public func socket(_ sock: GCDAsyncSocket, didConnectToHost host: String, port: UInt16) {
        guard let peer = sock.peer else {
            DLog("BluepeerObject: WARNING, did not find peer in didConnectToHost, doing nothing")
            return
        }
        peer.state = .awaitingAuth
        DLog("BluepeerObject: got to state = awaitingAuth with \(sock.connectedHost), sending name then awaiting ACK ('0')")
        
        // make 32-byte UTF-8 name
        let strData = NSMutableData.init(capacity: 32)
        for c in self.displayName.characters {
            if let thisData = String.init(c).data(using: String.Encoding.utf8) {
                if thisData.count + (strData?.length)! < 32 {
                    strData?.append(thisData)
                } else {
                    DLog("BluepeerObject: max displayName length reached, truncating")
                    break
                }
            }
        }
        // pad to 32 bytes!
        let paddedStrData: NSMutableData = ("                                ".data(using: String.Encoding.utf8) as NSData?)?.mutableCopy() as! NSMutableData // that's 32 spaces :)
        paddedStrData.replaceBytes(in: NSMakeRange(0, strData!.length), withBytes: (strData?.bytes)!)
        self.logDelegate?.didReadWrite("writeName")
        
        DLog("didConnect, writing name: \((paddedStrData as Data).hex)")
        sock.write(paddedStrData as Data, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_WRITING.rawValue)
        
        // now await auth
        self.logDelegate?.didReadWrite("readAuth")
        sock.readData(toLength: 1, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_AUTH.rawValue)
    }
    
    public func socketDidDisconnect(_ sock: GCDAsyncSocket, withError err: Error?) {
        guard let peerIndex = self.peers.index(where: {sock == $0.socket}) else {
            DLog("BluepeerObject socketDidDisconnect: WARNING, expected to find a peer, calling peerConnectionAttemptFailed")
            sock.synchronouslySetDelegate(nil)
            self.dispatch_on_delegate_queue({
                self.sessionDelegate?.peerConnectionAttemptFailed?(.unknown, peer: nil, isAuthRejection: false)
            })
            return
        }
        let peer = self.peers[peerIndex]
        DLog("BluepeerObject: \(peer.displayName) @ \(peer.socket?.connectedHost) disconnected. Peers.count: \(self.peers.count)")
        let oldState = peer.state
        peer.state = .notConnected
        peer.keepaliveTimer?.invalidate()
        peer.keepaliveTimer = nil
        peer.socket = nil
        sock.synchronouslySetDelegate(nil)
        switch oldState {
        case .connected:
            self.peers.remove(at: peerIndex)
            DLog("BluepeerObject: removed peer. New peers.count: \(self.peers.count)")
            self.dispatch_on_delegate_queue({
                self.sessionDelegate?.peerDidDisconnect?(peer.role, peer: peer)
            })
        case .notConnected:
            self.peers.remove(at: peerIndex)
            DLog("BluepeerObject: removed peer. New peers.count: \(self.peers.count)")
            assert(false, "ERROR: state is being tracked wrong")
        case .connecting, .awaitingAuth:
            // don't remove peer in this case
            self.dispatch_on_delegate_queue({
                self.sessionDelegate?.peerConnectionAttemptFailed?(peer.role, peer: peer, isAuthRejection: oldState == .awaitingAuth)
            })
        }
    }
    
    public func socket(_ sock: GCDAsyncSocket, didRead data: Data, withTag tag: Int) {
        
//        DLog("socket reads: \(data.hex)")
        
        guard let peer = sock.peer else {
            DLog("BluepeerObject: WARNING, did not find peer in didReadData, doing nothing")
            return
        }
        self.scheduleNextKeepaliveTimer(peer)

        if tag == DataTag.tag_AUTH.rawValue {
            assert(data.count == 1, "ERROR: not right length of bytes")
            var ack: UInt8 = 1
            (data as NSData).getBytes(&ack, length: 1)
            assert(ack == 0, "ERROR: not the right ACK")
            assert(peer.state == .awaitingAuth, "ERROR: expect I only get this while awaiting auth")
            peer.state = .connected // CLIENT becomes connected
            self.dispatch_on_delegate_queue({
                self.sessionDelegate?.peerDidConnect?(peer.role, peer: peer)
            })
            self.logDelegate?.didReadWrite("readHeaderTerminator1")
            sock.readData(to: self.headerTerminator, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_HEADER.rawValue)
            
        } else if tag == DataTag.tag_HEADER.rawValue {
            // first, strip the trailing headerTerminator
            let range = 0..<data.count-self.headerTerminator.count
            let dataWithoutTerminator = data.subdata(in: Range(range))
            if dataWithoutTerminator == self.keepAliveHeader {
                DLog("BluepeerObject: got keepalive")
                self.logDelegate?.didReadWrite("readHeaderTerminator2")
                sock.readData(to: self.headerTerminator, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_HEADER.rawValue)
            } else {
                // take the first 4 bytes and use them as UInt of length of data. read the next 4 bytes and discard for now, might use them as version code? in future
                
                var length: UInt = 0
                (dataWithoutTerminator as NSData).getBytes(&length, length: 4)
                // ignore bytes 4-8 for now
                DLog("BluepeerObject: got header, reading \(length) bytes...")
                self.logDelegate?.didReadWrite("readBody")
                sock.readData(toLength: length, withTimeout: Timeouts.body.rawValue, tag: DataTag.tag_BODY.rawValue)
            }
            
        } else if tag == DataTag.tag_NAME.rawValue {
            
            var name = String.init(data: data, encoding: String.Encoding.utf8)
            if name == nil {
                name = "Unknown"
            }
            name = name?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
            peer.displayName = name!
            
            if let delegate = self.sessionDelegate {
                self.dispatch_on_delegate_queue({
                    delegate.peerConnectionRequest?(peer, invitationHandler: { (inviteAccepted) in
                        if inviteAccepted && peer.state == .awaitingAuth && sock.isConnected == true {
                            peer.state = .connected // SERVER becomes connected
                            // CONVENTION: SERVER sends CLIENT a single 0 to show connection has been accepted, since it isn't possible to send a header for a payload of size zero except here.
                            self.logDelegate?.didReadWrite("writeAcceptance")
                            sock.write(Data.init(count: 1), withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_WRITING.rawValue)
                            DLog("... accepted (by my delegate)")
                            self.dispatch_on_delegate_queue({
                                self.sessionDelegate?.peerDidConnect?(.client, peer: peer)
                            })
                            self.logDelegate?.didReadWrite("readHeaderTerminator3")
                            sock.readData(to: self.headerTerminator, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_HEADER.rawValue)
                        } else {
                            peer.state = .notConnected
                            sock.synchronouslySetDelegate(nil)
                            sock.disconnect()
                            peer.socket = nil
                            DLog("... rejected (by my delegate), or no longer connected")
                        }
                    })
                })
            }
            
        } else { // BODY case
            self.dispatch_on_delegate_queue({
                self.dataDelegate?.didReceiveData(data, fromPeer: peer)
            })
            self.logDelegate?.didReadWrite("readHeaderTerminator4")
            sock.readData(to: self.headerTerminator, withTimeout: Timeouts.header.rawValue, tag: DataTag.tag_HEADER.rawValue)
        }
    }
    
    public func socket(_ sock: GCDAsyncSocket, didReadPartialDataOfLength partialLength: UInt, tag: Int) {
        guard let peer = sock.peer else {
            return
        }
        self.scheduleNextKeepaliveTimer(peer)
    }
    
    public func socket(_ sock: GCDAsyncSocket, shouldTimeoutReadWithTag tag: Int, elapsed: TimeInterval, bytesDone length: UInt) -> TimeInterval {
        return self.calcTimeExtension(sock, tag: tag)
    }
    
    public func calcTimeExtension(_ sock: GCDAsyncSocket, tag: Int) -> TimeInterval {
        guard let peer = sock.peer else {
            return 0
        }
        
        let timeSinceLastData = abs(peer.lastReceivedData.timeIntervalSinceNow)
        if timeSinceLastData > (2.0 * Timeouts.keepAlive.rawValue) {
            // timeout!
            DLog("BluepeerObject: socket timed out waiting for read/write - data last seen \(timeSinceLastData). Tag: \(tag). Disconnecting.")
            sock.disconnect()
            return 0
        } else {
            // extend
            DLog("BluepeerObject: extending socket timeout by \(Timeouts.keepAlive.rawValue)s bc I saw data \(timeSinceLastData)s ago")
            return Timeouts.keepAlive.rawValue
        }
    }
}

extension BluepeerObject: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        DLog("Bluetooth status: ")
        switch (self.bluetoothPeripheralManager.state) {
        case .unknown:
            DLog("Unknown")
            self.bluetoothState = .unknown
        case .resetting:
            DLog("Resetting")
            self.bluetoothState = .other
        case .unsupported:
            DLog("Unsupported")
            self.bluetoothState = .other
        case .unauthorized:
            DLog("Unauthorized")
            self.bluetoothState = .other
        case .poweredOff:
            DLog("PoweredOff")
            self.bluetoothState = .poweredOff
        case .poweredOn:
            DLog("PoweredOn")
            self.bluetoothState = .poweredOn
        }
        self.bluetoothBlock?(self.bluetoothState)
    }
}

extension CharacterSet {
    func containsCharacter(_ c:Character) -> Bool {
        let s = String(c)
        let result = s.rangeOfCharacter(from: self)
        return result != nil
    }
}

extension Data {
    var hex: String {
        return self.map { b in String(format: "%02X", b) }.joined()
    }
}
