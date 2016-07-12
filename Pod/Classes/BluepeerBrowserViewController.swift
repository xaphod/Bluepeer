//
//  BluepeerBrowserViewController.swift
//
//  Created by Tim Carr on 7/11/16.
//  Copyright © 2016 Tim Carr Photo. All rights reserved.
//

import UIKit
import xaphodObjCUtils

@objc public class BluepeerBrowserViewController: UITableViewController {

    var bluepeerObject: BluepeerObject?
    var bluepeerSuperSessionDelegate: BluepeerSessionManagerDelegate?
    public var browserCompletionBlock: (Bool -> ())?
    var peers: [(peer: BPPeer, inviteBlock: (connect: Bool, timeoutForInvite: NSTimeInterval) -> Void)] = []
    var progressView: XaphodProgressView?
    var lastTimerStarted: NSDate?
    var timer: NSTimer?

    @IBOutlet weak var cancelButton: UIBarButtonItem!
    
    override public var preferredContentSize: CGSize {
        get {
            return CGSizeMake(320, 280)
        }
        set {
            preferredContentSize = newValue
        }
    }
    
    
    override public func viewDidLoad() {
        super.viewDidLoad()
        guard let bo = bluepeerObject else {
            assert(false, "ERROR: set bluepeerObject before loading view")
            return
        }
        self.bluepeerSuperSessionDelegate = bo.sessionDelegate
        bo.sessionDelegate = self
        bo.startBrowsing()
    }
    
    override public func viewWillAppear(animated: Bool) {
        super.viewWillAppear(animated)
//        let popoverPresentationVC = self.parentViewController?.popoverPresentationController
//        if (popoverPresentationVC != nil && UIPopoverArrowDirection.Unknown.rawValue > popoverPresentationVC!.arrowDirection.rawValue) {
//            self.navigationItem.setLeftBarButtonItem(nil, animated: false)
//        } else {
//            // presented as modal view controller (on iPhone)
//        }
    }
    
    override public func viewWillDisappear(animated: Bool) {
        super.viewWillDisappear(animated)
        self.bluepeerObject?.stopBrowsing()
        self.bluepeerObject?.sessionDelegate = self.bluepeerSuperSessionDelegate
        self.bluepeerObject = nil
        self.lastTimerStarted = nil
        self.timer?.invalidate()
        self.timer = nil
    }

    // MARK: - Table view data source

    override public func numberOfSectionsInTableView(tableView: UITableView) -> Int {
        return 1
    }

    override public func tableView(tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return max(self.peers.count, 1)
    }

    override public func tableView(tableView: UITableView, cellForRowAtIndexPath indexPath: NSIndexPath) -> UITableViewCell {
        var cell: BluepeerRowTableViewCell
        if self.peers.count == 0 {
            // loading row
            cell = tableView.dequeueReusableCellWithIdentifier("loadingRow", forIndexPath: indexPath) as! BluepeerRowTableViewCell
            cell.celltype = .LoadingRow
        } else {
            cell = tableView.dequeueReusableCellWithIdentifier("peerRow", forIndexPath: indexPath) as! BluepeerRowTableViewCell
            cell.celltype = .NormalRow
            cell.peer = self.peers[indexPath.row].peer
        }
        cell.updateDisplay()
        
        return cell
    }
    
    override public func tableView(tableView: UITableView, willSelectRowAtIndexPath indexPath: NSIndexPath) -> NSIndexPath? {
        if self.peers.count == 0 {
            return nil
        } else {
            return indexPath
        }
    }

    override public func tableView(tableView: UITableView, didSelectRowAtIndexPath indexPath: NSIndexPath) {
        self.progressView = XaphodProgressView.init(view: self.view)
        self.view.addSubview(self.progressView!)
        self.progressView!.text = ""
        self.progressView!.showWithAnimation(true)
        self.lastTimerStarted = NSDate.init()
        self.timer = NSTimer.scheduledTimerWithTimeInterval(60.0, target: self, selector: #selector(timerFired), userInfo: nil, repeats: false)
        
        let peer = self.peers[indexPath.row]
        peer.inviteBlock(connect: true, timeoutForInvite: 20.0)
    }
    
    @IBAction func cancelPressed(sender: AnyObject) {
        self.bluepeerObject?.disconnectSession()
        self.dismissViewControllerAnimated(true, completion: nil)
    }
    
    func timerFired(timer: NSTimer) {
        NSLog("Timer fired.")
        if let _ = self.lastTimerStarted {
            if (self.progressView != nil) {
                self.progressView?.dismissWithAnimation(true)
                self.progressView = nil
            }
        }
    }
}

extension BluepeerBrowserViewController: BluepeerSessionManagerDelegate {
    
    public func peerDidConnect(peerRole: RoleType, peer: BPPeer) {
        NSLog("BluepeerBrowserVC: connected, dismissing.")
        self.progressView?.dismissWithAnimation(false)
        self.progressView = nil
        self.lastTimerStarted = nil
        self.timer?.invalidate()
        self.timer = nil

        self.dismissViewControllerAnimated(true, completion: {
            self.browserCompletionBlock?(true)
        })
    }
    
    public func peerConnectionAttemptFailed(peerRole: RoleType, peer: BPPeer, isAuthRejection: Bool) {
        if (isAuthRejection) {
            self.progressView?.dismissWithAnimation(false)
            self.progressView = nil
            self.lastTimerStarted = nil
            self.timer?.invalidate()
            self.timer = nil

            self.dismissViewControllerAnimated(true, completion: {
                self.browserCompletionBlock?(false)
            })
        } else {
            // TODO: RETRY! just once?
            NSLog("Non auth fail")
        }
    }
    
    public func browserFoundPeer(role: RoleType, peer: BPPeer, inviteBlock: (connect: Bool, timeoutForInvite: NSTimeInterval) -> Void) {
        self.peers.append((peer: peer, inviteBlock: inviteBlock))
        self.tableView.reloadData()
    }
    
    public func browserLostPeer(role: RoleType, peer: BPPeer) {
        self.progressView?.dismissWithAnimation(false)
        self.progressView = nil
        self.lastTimerStarted = nil
        self.timer?.invalidate()
        self.timer = nil
        if let index = self.peers.indexOf({$0.0 == peer}) {
            self.peers.removeAtIndex(index)
            self.tableView.reloadData()
        }
    }
}
