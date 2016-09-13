# Bluepeer

Bluepeer provides an adhoc Bluetooth layer for iOS 8+. Bluepeer is designed to be a MultiPeer replacement (Multipeer is Apple's MultipeerFramework, which lives inside GameKit). The APIs are as similar as possible in order to aid with migrations. Bluepeer has some key differences from Multipeer:

- Exposes a role-based system to more easily support client/server dichotomies (but you can set up roles however you like)
- Uses sockets, TCP & unicast only (is not multicast like Multipeer is, and does not support UDP)
- Can specify Bluetooth-only, instead of being forced to always use wifi with Multipeer
- Is ideal for environments where devices are coming and going all the time, ie. you never call `stopAdvertising()`

Bluepeer was written because Apple's Multipeer has a severe negative impact on wifi throughput / performance if you leave advertising on -- while advertising, wifi throughput is limited to about 100kB/sec instead of >1MB/sec on an iPad Air. That's why Apple advises that you call `stopAdvertising()` as soon as possible. Bluepeer avoids this by allowing advertising to only occur on the Bluetooth stack.

Bluepeer is written in Swift, uses only publicly-accessible Apple APIs, and **is published in several apps on the Apple App Store** including [WiFi Booth](http://thewifibooth.com) and [BluePrint](https://thewifibooth.com/blueprint/).

### UPDATED FOR XCODE 8 / SWIFT 3.0
In mid-september 2016 this was updated to Swift 3.0. You can roll back to older version 1.0.11 if you can't consume Swift 3.0 in your project yet. Please note that the code snippets below in this file have not been updated.

### Requirements
See the Podfile: Bluepeer requires `xaphodObjCUtils` from GitHub/Xaphod, and `HHServices` + `CocoaAsyncSocket` from the master cocoapods repo.

### Installation

Easiest way is with Pods -- edit your Podfile and add

```
source 'https://github.com/xaphod/podspecs.git'
pod 'Bluepeer'
```
... and then `pod install`

### Usage

Very similar to Multipeer. 

First, init a BluepeerObject.

```let bluepeer = BluepeerObject.init(serviceType: "serviceTypeStr", displayName: nil, queue: nil, serverPort: XaphodUtils.getFreeTCPPort(), overBluetoothOnly: btOnly, bluetoothBlock: nil)```

**serviceType** - Be careful with the serviceType, it needs to be a short string of *only* alphabetic characters (as it is the basis of a DNS TXT record). 

**displayName** - Optional. Specify a displayName if you wish other peers to see a specific name for this device; otherwise, the device's name will be used if you specify nil. 

**queue** - Optional. All delegate calls with be dispatched on this queue. If you leave it as nil, the main queue will be used.

**serverPort** - Which TCP port will be used. Use getFreeTCPPort() as in the example above to retrieve a random port. The other devices do NOT need to know this, as it is auto-discovered via DNS TXT records.

If you want to warn the user when Bluetooth is off, then set the bluetoothBlock like this:

            bluepeer.bluetoothBlock = { (state: BluetoothState) in
            if state == .PoweredOff {
                let alert = UIAlertController.init(title: "Bluetooth is Off", message: "This app can use both Bluetooth and WiFi. Bluetooth is almost always required. Please turn on Bluetooth now.", preferredStyle: .Alert)
                alert.addAction(UIAlertAction.init(title: "Cancel", style: .Cancel, handler: nil))
                alert.addAction(UIAlertAction.init(title: "Open Settings", style: .Default, handler: { (_) in
                    UIApplication.sharedApplication().openURL(NSURL.init(string: UIApplicationOpenSettingsURLString)!)
                }))
                self.presentViewController(alert, animated: true, completion: nil)
            }
        }

At this point, someone needs to start advertising the service. Bluepeer has Server/Client roles built-in, here we'll be the server:

        bluepeer.sessionDelegate = self
        bluepeer.dataDelegate = self
        bluepeer.startAdvertising(.Server)

... so we need to implement the sessionDelegate:

    extension SomeClass: BluepeerSessionManagerDelegate {
        func peerConnectionRequest(peer: BPPeer, invitationHandler: (Bool) -> Void) {
            // ask the user if they want to accept the incoming connection. 
            // call invitationHandler(true) or invitationHandler(false) accordingly
        }
        
        func peerDidConnect(peerRole: RoleType, peer: BPPeer) {
            // when a peer has successfully connected
        }
        
        func peerDidDisconnect(peerRole: RoleType, peer: BPPeer) {
            // when a peer has disconnected (intentionally, or lost connection)
        }
    }

... and the dataDelegate:

    extension SomeClass: BluepeerDataDelegate {
        func didReceiveData(data: NSData, fromPeer peerID: BPPeer) {
            // received data from BPPeer fromPeer ! do something with it
        }
    }

On the side that needs to initiate the connection, you have a couple of options. You can do it programmatically, or you can present a browser to the user like this:

        let browserViewController = bluepeer.getBrowser { (success) in
        if (success) {
            self.performSegueWithIdentifier("segueToSomewhere", sender: self)
        }
        
        if (UIDevice.currentDevice().userInterfaceIdiom == .Phone) {
            presentViewController(browser, animated: true, completion: nil)
        } else {
            browser.modalPresentationStyle = .Popover
            if let popBrowser: UIPopoverPresentationController = browser.popoverPresentationController {
                popBrowser.sourceView = self.view
                popBrowser.sourceRect = self.someButton.frame
                presentViewController(browser, animated: true, completion: nil)
            }
        }

To send data, you can use either toRole or toPeers depending on what you want:

    bluepeer.sendData([imageData], toRole: .Server)
... will send to all connected BPPeer with the role Server

    bluepeer.sendData([imageData], toPeers: [peer1, peer2])
... will send to peer1 and peer2.

Because Apple does not allow adhoc networking like this to function while the app is in the background, BluepeerObjects will automatically disconnect themselves when your app resigns active.

 
