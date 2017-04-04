//
//  BluepeerNavigationController.swift
//  Pods
//
//  Created by Tim Carr on 7/12/16.
//
//

import UIKit

class BluepeerNavigationController: UINavigationController {
    
    override var preferredContentSize: CGSize {
        get {
            if let size = self.topViewController?.preferredContentSize {
                return size
            } else {
                return self.preferredContentSize
            }
        }
        set {
            self.preferredContentSize = newValue
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // Do any additional setup after loading the view.
    }
}
