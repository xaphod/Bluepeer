//
//  BluepeerBrowserViewController.swift
//  Photobooth
//
//  Created by Tim Carr on 7/11/16.
//  Copyright © 2016 Tim Carr Photo. All rights reserved.
//

import UIKit

@objc public class BluepeerBrowserViewController: UITableViewController {

    var bluepeerObject: BluepeerObject?
    var bluepeerSuperSessionDelegate: BluepeerSessionManagerDelegate?
    var peers: [(peer: BPPeer, inviteBlock: (connect: Bool, timeoutForInvite: NSTimeInterval) -> Void)] = []
    
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
    
    override public func viewWillDisappear(animated: Bool) {
        super.viewWillDisappear(animated)
        self.bluepeerObject?.stopBrowsing()
        self.bluepeerObject?.sessionDelegate = self.bluepeerSuperSessionDelegate
        self.bluepeerObject = nil
    }

    // MARK: - Table view data source

    override public func numberOfSectionsInTableView(tableView: UITableView) -> Int {
        return 1
    }

    override public func tableView(tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        return self.peers.count
    }

    override public func tableView(tableView: UITableView, cellForRowAtIndexPath indexPath: NSIndexPath) -> UITableViewCell {
        // TODO: min rows is 1, show spinner/loading row...
        let cell = tableView.dequeueReusableCellWithIdentifier("peerRow", forIndexPath: indexPath) as! BluepeerRowTableViewCell
        let peer = self.peers[indexPath.row] // TODO: can't this throw arrayindexoutofbounds exception? tried try/catch, didn't seem to work
        cell.mainLabel.text = peer.peer.displayName
        return cell
    }

    override public func tableView(tableView: UITableView, didSelectRowAtIndexPath indexPath: NSIndexPath) {
        let peer = self.peers[indexPath.row] // TODO: can't this throw arrayindexoutofbounds exception? tried try/catch, didn't seem to work
        peer.inviteBlock(connect: true, timeoutForInvite: 20.0)
        // TODO: show progressView..
    }
}

extension BluepeerBrowserViewController: BluepeerSessionManagerDelegate {
    
    public func peerDidConnect(peerRole: RoleType, peer: BPPeer) {
        NSLog("BluepeerBrowserVC: connected, dismissing.")
        self.dismissViewControllerAnimated(true, completion: nil)
    }
    
    public func peerConnectionAttemptFailed(peerRole: RoleType, peer: BPPeer) {
        // TODO: try again
    }
    
    public func browserFoundPeer(role: RoleType, peer: BPPeer, inviteBlock: (connect: Bool, timeoutForInvite: NSTimeInterval) -> Void) {
        self.peers.append((peer: peer, inviteBlock: inviteBlock))
        self.tableView.reloadData()
    }
}
