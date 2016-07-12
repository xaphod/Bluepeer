//
//  BluepeerRowTableViewCell.swift
//  Photobooth
//
//  Created by Tim Carr on 7/11/16.
//  Copyright © 2016 Tim Carr Photo. All rights reserved.
//

import UIKit

enum CellType {
    case LoadingRow
    case NormalRow
}

@objc public class BluepeerRowTableViewCell: UITableViewCell {
    
    var celltype: CellType = .NormalRow
    var peer: BPPeer?

    @IBOutlet weak var mainLabel: UILabel!
    @IBOutlet weak var activityIndicator: UIActivityIndicatorView!
    
    override public func awakeFromNib() {
        super.awakeFromNib()
        // Initialization code
    }

    override public func setSelected(selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)

        // Configure the view for the selected state
    }
    
    public func updateDisplay() {
        switch celltype {
        case .LoadingRow:
            self.mainLabel.text = "Searching..."
            self.selectionStyle = .None
            self.activityIndicator.startAnimating()
            
        case .NormalRow:
            self.mainLabel.text = peer != nil ? peer!.displayName : "Unknown"
            self.selectionStyle = .Default
        }
    }
}
