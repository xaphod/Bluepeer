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
    var bluepeerSuperAdminDelegate: BluepeerMembershipAdminDelegate?
    var bluepeerSuperRosterDelegate: BluepeerMembershipRosterDelegate?
    open var browserCompletionBlock: ((Bool) -> ())?
    var peers: [BPPeer] = []
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
        self.setNeedsStatusBarAppearanceUpdate()
        guard let bo = bluepeerObject else {
            assert(false, "ERROR: set bluepeerObject before loading view")
            return
        }
        // this should be in viewDidLoad.
        self.bluepeerSuperAdminDelegate = bo.membershipAdminDelegate
        self.bluepeerSuperRosterDelegate = bo.membershipRosterDelegate
        bo.membershipRosterDelegate = self
        bo.membershipAdminDelegate = self
        bo.startBrowsing()
    }
    
    override open func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
    }
    
    override open func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        self.bluepeerObject?.stopBrowsing()
        self.bluepeerObject?.membershipAdminDelegate = self.bluepeerSuperAdminDelegate
        self.bluepeerObject?.membershipRosterDelegate = self.bluepeerSuperRosterDelegate
        self.bluepeerObject = nil
        self.lastTimerStarted = nil
        self.timer?.invalidate()
        self.timer = nil
    }

    override open var prefersStatusBarHidden: Bool {
        return false
    }
    
    override open var preferredStatusBarStyle: UIStatusBarStyle {
        return .default
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
            cell.peer = self.peers[(indexPath as NSIndexPath).row]
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
        peer.connect?()
    }
    
    @IBAction func cancelPressed(_ sender: AnyObject) {
        self.bluepeerObject?.disconnectSession()
        self.dismiss(animated: true, completion: {
            self.browserCompletionBlock?(false)
        })
    }
    
    @objc func timerFired(_ timer: Timer) {
        NSLog("Timer fired.")
        if let _ = self.lastTimerStarted {
            if (self.progressView != nil) {
                self.progressView?.dismiss(withAnimation: true)
                self.progressView = nil
            }
        }
    }
}

extension BluepeerBrowserViewController: BluepeerMembershipRosterDelegate {
    public func bluepeer(_ bluepeerObject: BluepeerObject, peerDidConnect peerRole: RoleType, peer: BPPeer) {
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
    
    public func bluepeer(_ bluepeerObject: BluepeerObject, peerConnectionAttemptFailed peerRole: RoleType, peer: BPPeer?, isAuthRejection: Bool, canConnectNow: Bool) {
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
}

extension BluepeerBrowserViewController: BluepeerMembershipAdminDelegate {
    public func bluepeer(_ bluepeerObject: BluepeerObject, browserFoundPeer role: RoleType, peer: BPPeer) {
        DispatchQueue.main.async(execute: {
            if !self.peers.contains(peer) {
                self.peers.append(peer)
                self.tableView.reloadData()
            }
        })
    }
    
    public func bluepeer(_ bluepeerObject: BluepeerObject, browserLostPeer role: RoleType, peer: BPPeer) {
        DispatchQueue.main.async(execute: {
            self.progressView?.dismiss(withAnimation: false)
            self.progressView = nil
            self.lastTimerStarted = nil
            self.timer?.invalidate()
            self.timer = nil
            if let index = self.peers.index(where: {$0 == peer}) {
                self.peers.remove(at: index)
                self.tableView.reloadData()
            }
        })
    }
}
