//
//  BluepeerRowTableViewCell.swift
//
//  Created by Tim Carr on 7/11/16.
//  Copyright © 2016 Tim Carr Photo. All rights reserved.
//

import UIKit

enum CellType {
    case loadingRow
    case normalRow
}

@objc open class BluepeerRowTableViewCell: UITableViewCell {
    
    var celltype: CellType = .normalRow
    var peer: BPPeer?

    @IBOutlet weak var mainLabel: UILabel!
    @IBOutlet weak var activityIndicator: UIActivityIndicatorView!
    
    override open func awakeFromNib() {
        super.awakeFromNib()
        // Initialization code
    }

    override open func setSelected(_ selected: Bool, animated: Bool) {
        super.setSelected(selected, animated: animated)

        // Configure the view for the selected state
    }
    
    open func updateDisplay() {
        switch celltype {
        case .loadingRow:
            self.mainLabel.text = "Searching..."
            self.selectionStyle = .none
            self.activityIndicator.startAnimating()
            
        case .normalRow:
            self.mainLabel.text = peer != nil ? peer!.displayName : "Unknown"
            self.selectionStyle = .default
        }
    }
}
