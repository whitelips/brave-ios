/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit
import Shared
import BraveShared

@objc protocol FavoriteCellDelegate {
    func editFavorite(_ favoriteCell: FavoriteCell)
}

class FavoriteCell: UICollectionViewCell {
    static let imageAspectRatio: Float = 1.0
    static let placeholderImage = #imageLiteral(resourceName: "defaultTopSiteIcon")
    static let identifier = "FavoriteCell"
    
    private struct UI {
        /// Ratio of width:height of the thumbnail image.
        static let cornerRadius: CGFloat = 8
        static let spacing: CGFloat = 8
        static let labelAlignment: NSTextAlignment = .center
    }
    
    weak var delegate: FavoriteCellDelegate?
    
    var imageInsets: UIEdgeInsets = UIEdgeInsets.zero
    var cellInsets: UIEdgeInsets = UIEdgeInsets.zero
    
    /// Legacy long press gesture handler.
    /// Only is excecuted when user is running
    /// on iOS 12
    var longPressHandler: ((FavoriteCell) -> Void)?
    
    let textLabel = UILabel().then {
        $0.setContentHuggingPriority(UILayoutPriority.defaultHigh, for: NSLayoutConstraint.Axis.vertical)
        $0.font = DynamicFontHelper.defaultHelper.DefaultSmallFont
        $0.appearanceTextColor = .white
        $0.textAlignment = UI.labelAlignment
        $0.lineBreakMode = NSLineBreakMode.byWordWrapping
        $0.numberOfLines = 2
    }
    
    let imageView = UIImageView().then {
        $0.contentMode = .scaleAspectFit
        $0.clipsToBounds = true
        $0.layer.cornerRadius = UI.cornerRadius
        if #available(iOS 13.0, *) {
            $0.layer.cornerCurve = .continuous
        }
        $0.layer.borderColor = BraveUX.faviconBorderColor.cgColor
        $0.layer.borderWidth = BraveUX.faviconBorderWidth
        $0.layer.minificationFilter = CALayerContentsFilter.trilinear
        $0.layer.magnificationFilter = CALayerContentsFilter.nearest
    }
    
    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.25, delay: 0, options: [.beginFromCurrentState], animations: {
                self.imageView.alpha = self.isHighlighted ? 0.7 : 1.0
            })
        }
    }
    
    let stackView = UIStackView().then {
        $0.axis = .vertical
        $0.spacing = UI.spacing
        $0.alignment = .center
        $0.isUserInteractionEnabled = false
    }
    
    override init(frame: CGRect) {
        super.init(frame: frame)
        
        isAccessibilityElement = true
        
        contentView.addSubview(stackView)
        stackView.addArrangedSubview(imageView)
        stackView.addArrangedSubview(textLabel)
        
        imageView.snp.makeConstraints {
            $0.height.equalTo(imageView.snp.width)
            $0.leading.trailing.equalToSuperview().inset(12)
        }
        stackView.snp.makeConstraints {
            $0.top.leading.trailing.equalToSuperview()
            $0.bottom.lessThanOrEqualToSuperview()
        }
        
        // Prevents the textLabel from getting squished in relation to other view priorities.
        textLabel.setContentCompressionResistancePriority(.defaultHigh, for: .vertical)
        
        if #available(iOS 13.4, *) {
            addInteraction(UIPointerInteraction(delegate: self))
        }
        
        if #available(iOS 13.0, *) {
        } else {
            // iOS 12 long-press support
            let longPress = UILongPressGestureRecognizer(target: self, action: #selector(handleLongPress(_:)))
            addGestureRecognizer(longPress)
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self, name: .thumbnailEditOn, object: nil)
        NotificationCenter.default.removeObserver(self, name: .thumbnailEditOff, object: nil)
    }
    
    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func prepareForReuse() {
        super.prepareForReuse()
        backgroundColor = UIColor.clear
        imageView.backgroundColor = UIColor.clear
        imageView.image = nil
    }
    
    private func updateSelectedHighlightedState() {
        let activatedAlpha: CGFloat = 0.7
        let disactivatedAlpha: CGFloat = 1.0
        
        let activated = isSelected || isHighlighted
        self.imageView.alpha = activated ? activatedAlpha : disactivatedAlpha
    }
    
    @objc private func handleLongPress(_ gesture: UILongPressGestureRecognizer) {
        if gesture.state == .began {
            longPressHandler?(self)
        }
    }
    
    override func preferredLayoutAttributesFitting(_ layoutAttributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        // Size of cells are determined outside of cell
        return layoutAttributes
    }
    
    static func height(forWidth width: CGFloat) -> CGFloat {
        let imageHeight = (width - 24)
        let labelHeight = (DynamicFontHelper.defaultHelper.DefaultSmallFont.lineHeight * 2)
        return ceil(imageHeight + UI.spacing + labelHeight)
    }
}

@available(iOS 13.4, *)
extension FavoriteCell: UIPointerInteractionDelegate {
    func pointerInteraction(_ interaction: UIPointerInteraction, styleFor region: UIPointerRegion) -> UIPointerStyle? {
        let preview = UITargetedPreview(view: imageView)
        return UIPointerStyle(effect: .highlight(preview))
    }
}
