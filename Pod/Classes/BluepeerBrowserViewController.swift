//
//  BluepeerBrowserViewController.swift
//
//  Created by Tim Carr on 7/11/16.
//  Copyright © 2016 Tim Carr Photo. All rights reserved.
//

import UIKit
import xaphodObjCUtils

@objc open class BluepeerBrowserViewController: UITableViewController {

    var bluepeerObject: BluepeerObject?
    var bluepeerSuperSessionDelegate: BluepeerSessionManagerDelegate?
    open var browserCompletionBlock: ((Bool) -> ())?
    var peers: [(peer: BPPeer, inviteBlock: (_ timeoutForInvite: TimeInterval) -> Void)] = []
    var progressView: XaphodProgressView?
    var lastTimerStarted: Date?
    var timer: Timer?

    @IBOutlet weak var cancelButton: UIBarButtonItem!
    
    override open var preferredContentSize: CGSize {
        get {
            return CGSize(width: 320, height: 280)
        }
        set {
            self.preferredContentSize = newValue
        }
    }
    
    
    override open func viewDidLoad() {
        super.viewDidLoad()
        guard let bo = bluepeerObject else {
            assert(false, "ERROR: set bluepeerObject before loading view")
            return
        }
        self.bluepeerSuperSessionDelegate = bo.sessionDelegate
        bo.sessionDelegate = self
        bo.startBrowsing()
    }
    
    override open func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
//        let popoverPresentationVC = self.parentViewController?.popoverPresentationController
//        if (popoverPresentationVC != nil && UIPopoverArrowDirection.Unknown.rawValue > popoverPresentationVC!.arrowDirection.rawValue) {
//            self.navigationItem.setLeftBarButtonItem(nil, animated: false)
//        } else {
//            // presented as modal view controller (on iPhone)
//        }
    }
    
    override open func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.bluepeerObject?.stopBrowsing()
        self.bluepeerObject?.sessionDelegate = self.bluepeerSuperSessionDelegate
        self.bluepeerObject = nil
        self.lastTimerStarted = nil
        self.timer?.invalidate()
        self.timer = nil
    }

    // MARK: - Table view data source

    override open func numberOfSections(in tableView: UITableView) -> Int {
        return 1
    }

    override open func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return max(self.peers.count, 1)
    }

    override open func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        var cell: BluepeerRowTableViewCell
        if self.peers.count == 0 {
            // loading row
            cell = tableView.dequeueReusableCell(withIdentifier: "loadingRow", for: indexPath) as! BluepeerRowTableViewCell
            cell.celltype = .loadingRow
        } else {
            cell = tableView.dequeueReusableCell(withIdentifier: "peerRow", for: indexPath) as! BluepeerRowTableViewCell
            cell.celltype = .normalRow
            cell.peer = self.peers[(indexPath as NSIndexPath).row].peer
        }
        cell.updateDisplay()
        
        return cell
    }
    
    override open func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        if self.peers.count == 0 {
            return nil
        } else {
            return indexPath
        }
    }

    override open func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        self.progressView = XaphodProgressView.init(view: self.view)
        self.view.addSubview(self.progressView!)
        self.progressView!.text = ""
        self.progressView!.show(withAnimation: true)
        self.lastTimerStarted = Date.init()
        self.timer = Timer.scheduledTimer(timeInterval: 60.0, target: self, selector: #selector(timerFired), userInfo: nil, repeats: false)
        
        let peer = self.peers[(indexPath as NSIndexPath).row]
        peer.inviteBlock(20.0)
    }
    
    @IBAction func cancelPressed(_ sender: AnyObject) {
        self.bluepeerObject?.disconnectSession()
        self.dismiss(animated: true, completion: nil)
    }
    
    func timerFired(_ timer: Timer) {
        NSLog("Timer fired.")
        if let _ = self.lastTimerStarted {
            if (self.progressView != nil) {
                self.progressView?.dismiss(withAnimation: true)
                self.progressView = nil
            }
        }
    }
}

extension BluepeerBrowserViewController: BluepeerSessionManagerDelegate {
    
    public func peerDidConnect(_ peerRole: RoleType, peer: BPPeer) {
        DispatchQueue.main.async(execute: {
            NSLog("BluepeerBrowserVC: connected, dismissing.")
            self.progressView?.dismiss(withAnimation: false)
            self.progressView = nil
            self.lastTimerStarted = nil
            self.timer?.invalidate()
            self.timer = nil
            
            self.dismiss(animated: true, completion: {
                self.browserCompletionBlock?(true)
            })
        })
    }
    
    public func peerConnectionAttemptFailed(_ peerRole: RoleType, peer: BPPeer?, isAuthRejection: Bool) {
        DispatchQueue.main.async(execute: {
            self.progressView?.dismiss(withAnimation: false)
            self.progressView = nil
            self.lastTimerStarted = nil
            self.timer?.invalidate()
            self.timer = nil
            
            self.dismiss(animated: true, completion: {
                self.browserCompletionBlock?(false)
            })
        })
    }

    public func browserFoundPeer(_ role: RoleType, peer: BPPeer, inviteBlock: @escaping (_ timeoutForInvite: TimeInterval) -> Void) {
        DispatchQueue.main.async(execute: {
            self.peers.append((peer: peer, inviteBlock: inviteBlock))
            self.tableView.reloadData()
        })
    }
    
    public func browserLostPeer(_ role: RoleType, peer: BPPeer) {
        DispatchQueue.main.async(execute: {
            self.progressView?.dismiss(withAnimation: false)
            self.progressView = nil
            self.lastTimerStarted = nil
            self.timer?.invalidate()
            self.timer = nil
            if let index = self.peers.index(where: {$0.0 == peer}) {
                self.peers.remove(at: index)
                self.tableView.reloadData()
            }
        })
    }
}
