//
//  ChatTableView.swift
//  AngelLive
//
//  UIKit-based chat list for smoother scrolling
//

import SwiftUI
import UIKit
import AngelLiveCore

struct ChatTableView: UIViewRepresentable {
    let messages: [ChatMessage]
    @Binding var showJumpToLatest: Bool
    @Binding var scrollToBottomRequest: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> UITableView {
        let tableView = UITableView(frame: .zero, style: .plain)
        tableView.backgroundColor = .clear
        tableView.separatorStyle = .none
        tableView.showsVerticalScrollIndicator = false
        tableView.keyboardDismissMode = .interactive
        tableView.estimatedRowHeight = 44
        tableView.rowHeight = UITableView.automaticDimension
        tableView.contentInset = UIEdgeInsets(top: 12, left: 0, bottom: 0, right: 0)
        // 用 footer 占位代替 contentInset.bottom，避免影响底部滚动判断
        let footer = UIView(frame: CGRect(x: 0, y: 0, width: 0, height: 56))
        footer.backgroundColor = .clear
        tableView.tableFooterView = footer
        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        tableView.register(ChatBubbleCapsuleCell.self, forCellReuseIdentifier: ChatBubbleCapsuleCell.reuseIdentifier)
        tableView.register(ChatBubbleRoundedCell.self, forCellReuseIdentifier: ChatBubbleRoundedCell.reuseIdentifier)
        return tableView
    }

    func updateUIView(_ uiView: UITableView, context: Context) {
        context.coordinator.setShowJumpToLatest = { [self] value in
            if showJumpToLatest != value {
                DispatchQueue.main.async {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showJumpToLatest = value
                    }
                }
            }
        }
        context.coordinator.update(messages: messages, tableView: uiView)
        if scrollToBottomRequest {
            context.coordinator.scrollToBottom(in: uiView, animated: true)
            DispatchQueue.main.async {
                scrollToBottomRequest = false
                showJumpToLatest = false
            }
        }
    }

    final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
        private var messages: [ChatMessage] = []
        private var messageIDs: [UUID] = []
        private var userHasScrolledUp = false  // 用户主动上滑了
        private var isProgrammaticScroll = false  // 正在程序化滚动（非用户触发）
        private var cachedCellTypes: [UUID: Bool] = [:] // true = capsule, false = rounded
        private var lastTableWidth: CGFloat = 0
        var setShowJumpToLatest: ((Bool) -> Void)?

        func update(messages: [ChatMessage], tableView: UITableView) {
            let newIDs = messages.map { $0.id }
            let tableWidth = tableView.bounds.width
            
            // 宽度变化时，清除缓存并刷新
            if tableWidth != lastTableWidth && lastTableWidth > 0 {
                cachedCellTypes.removeAll()
                self.messages = messages
                messageIDs = newIDs
                lastTableWidth = tableWidth
                tableView.reloadData()
                tableView.layoutIfNeeded()
                if !userHasScrolledUp {
                    programmaticScrollToBottom(in: tableView, animated: false)
                }
                return
            }
            lastTableWidth = tableWidth
            
            if newIDs == messageIDs {
                return
            }

            let oldCount = messageIDs.count
            self.messages = messages
            messageIDs = newIDs

            if oldCount == 0 {
                tableView.reloadData()
                programmaticScrollToBottom(in: tableView, animated: false)
                return
            }

            // 直接 reloadData，简单可靠
            tableView.reloadData()
            
            if !userHasScrolledUp {
                programmaticScrollToBottom(in: tableView, animated: false)
            } else {
                setShowJumpToLatest?(true)
            }
        }

        /// 程序化滚动到底部（不触发 userHasScrolledUp）
        private func programmaticScrollToBottom(in tableView: UITableView, animated: Bool) {
            let row = messages.count - 1
            guard row >= 0 else { return }
            isProgrammaticScroll = true
            tableView.scrollToRow(at: IndexPath(row: row, section: 0), at: .bottom, animated: animated)
            if !animated {
                isProgrammaticScroll = false
            }
            setShowJumpToLatest?(false)
        }
        
        /// 外部请求滚动到底部（点击"查看最新评论"）
        func scrollToBottom(in tableView: UITableView, animated: Bool) {
            userHasScrolledUp = false
            programmaticScrollToBottom(in: tableView, animated: animated)
        }
        
        /// 判断消息是否为单行（使用胶囊样式）
        private func isSingleLine(message: ChatMessage, tableWidth: CGFloat) -> Bool {
            if let cached = cachedCellTypes[message.id] {
                return cached
            }
            
            let horizontalPadding: CGFloat = 16 * 2  // cell 左右边距
            let bubblePadding: CGFloat = 12 * 2      // bubble 内边距
            let spacing: CGFloat = 8                  // userName 和 message 之间的间距
            
            let availableWidth = tableWidth - horizontalPadding - bubblePadding
            
            let font = UIFont.preferredFont(forTextStyle: .caption1)
            let userNameFont = font.withWeight(.semibold)
            
            if message.isSystemMessage {
                let iconWidth: CGFloat = 14 + spacing
                let textWidth = availableWidth - iconWidth
                let messageSize = (message.message as NSString).boundingRect(
                    with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: UIFont.preferredFont(forTextStyle: .caption2)],
                    context: nil
                )
                let isSingle = messageSize.height <= font.lineHeight + 2
                cachedCellTypes[message.id] = isSingle
                return isSingle
            } else {
                let userNameSize = (message.userName as NSString).boundingRect(
                    with: CGSize(width: .greatestFiniteMagnitude, height: font.lineHeight),
                    options: [.usesLineFragmentOrigin],
                    attributes: [.font: userNameFont],
                    context: nil
                )
                let textWidth = availableWidth - userNameSize.width - spacing
                let messageSize = (message.message as NSString).boundingRect(
                    with: CGSize(width: textWidth, height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font],
                    context: nil
                )
                let isSingle = messageSize.height <= font.lineHeight + 2
                cachedCellTypes[message.id] = isSingle
                return isSingle
            }
        }

        // MARK: - UITableViewDataSource

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
            messages.count
        }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let message = messages[indexPath.row]
            let useCapsule = isSingleLine(message: message, tableWidth: tableView.bounds.width)
            
            if useCapsule {
                guard let cell = tableView.dequeueReusableCell(withIdentifier: ChatBubbleCapsuleCell.reuseIdentifier, for: indexPath) as? ChatBubbleCapsuleCell else {
                    return UITableViewCell()
                }
                cell.configure(with: message)
                return cell
            } else {
                guard let cell = tableView.dequeueReusableCell(withIdentifier: ChatBubbleRoundedCell.reuseIdentifier, for: indexPath) as? ChatBubbleRoundedCell else {
                    return UITableViewCell()
                }
                cell.configure(with: message)
                return cell
            }
        }

        // MARK: - UITableViewDelegate

        /// 用户开始手动拖拽 → 标记为用户主动滚动
        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            // 只有用户手指触发的拖拽才标记
            userHasScrolledUp = true
            setShowJumpToLatest?(true)
        }
        
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate {
                checkIfAtBottom(scrollView)
            }
        }
        
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            checkIfAtBottom(scrollView)
        }
        
        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            // 程序化滚动动画结束
            isProgrammaticScroll = false
            userHasScrolledUp = false
            setShowJumpToLatest?(false)
        }
        
        /// 用户拖拽结束后，检查是否已经滚到底部附近，如果是则恢复自动滚动
        private func checkIfAtBottom(_ scrollView: UIScrollView) {
            let contentHeight = scrollView.contentSize.height
            let visibleHeight = scrollView.bounds.height
            
            guard contentHeight > visibleHeight else {
                userHasScrolledUp = false
                setShowJumpToLatest?(false)
                return
            }
            
            let threshold: CGFloat = 80
            let offsetY = scrollView.contentOffset.y
            let maxOffset = contentHeight - visibleHeight
            
            if offsetY >= maxOffset - threshold {
                userHasScrolledUp = false
                setShowJumpToLatest?(false)
            }
        }
    }
}

// MARK: - Base Cell Class

class ChatBubbleBaseCell: UITableViewCell {
    let bubbleView = UIView()
    let stackView = UIStackView()
    let iconView = UIImageView()
    let userNameLabel = UILabel()
    let messageLabel = UILabel()
    
    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        setupUI()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func setupUI() {
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        let horizontalPadding: CGFloat = 16
        let verticalPadding = AppConstants.Spacing.xs

        bubbleView.translatesAutoresizingMaskIntoConstraints = false
        // 纯色背景 + 边框的圆角由 cornerRadius 本身绘制,无需 masksToBounds 裁剪。
        // 关掉 masksToBounds 避免每个气泡触发离屏渲染(offscreen rendering)——
        // 这是快速滚动弹幕列表「强制圆角」的主要性能开销。标签有内边距不会溢出圆角弧,安全。
        bubbleView.layer.masksToBounds = false
        bubbleView.layer.cornerCurve = .continuous
        contentView.addSubview(bubbleView)

        stackView.axis = .horizontal
        stackView.alignment = .top
        stackView.spacing = 8
        stackView.translatesAutoresizingMaskIntoConstraints = false
        bubbleView.addSubview(stackView)

        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = UIColor.systemYellow.withAlphaComponent(0.8)
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        userNameLabel.numberOfLines = 1
        userNameLabel.setContentHuggingPriority(.required, for: .horizontal)
        userNameLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        userNameLabel.adjustsFontForContentSizeCategory = true
        userNameLabel.font = UIFont.preferredFont(forTextStyle: .caption1).withWeight(.semibold)

        messageLabel.numberOfLines = 0
        messageLabel.adjustsFontForContentSizeCategory = true
        messageLabel.font = UIFont.preferredFont(forTextStyle: .caption1)
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            bubbleView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: verticalPadding),
            bubbleView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -verticalPadding),
            bubbleView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: horizontalPadding),
            bubbleView.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -horizontalPadding),

            stackView.topAnchor.constraint(equalTo: bubbleView.topAnchor, constant: 8),
            stackView.bottomAnchor.constraint(equalTo: bubbleView.bottomAnchor, constant: -8),
            stackView.leadingAnchor.constraint(equalTo: bubbleView.leadingAnchor, constant: 12),
            stackView.trailingAnchor.constraint(equalTo: bubbleView.trailingAnchor, constant: -12),

            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14)
        ])
    }
    
    func configure(with message: ChatMessage) {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if message.isSystemMessage {
            iconView.image = UIImage(systemName: "info.circle.fill")
            messageLabel.text = message.message
            messageLabel.textColor = UIColor.systemYellow.withAlphaComponent(0.9)
            messageLabel.font = UIFont.preferredFont(forTextStyle: .caption2)
            stackView.addArrangedSubview(iconView)
            stackView.addArrangedSubview(messageLabel)

            bubbleView.backgroundColor = UIColor.black.withAlphaComponent(AppConstants.PlayerUI.Opacity.overlayMedium)
            bubbleView.layer.borderColor = UIColor.systemYellow.withAlphaComponent(0.3).cgColor
            bubbleView.layer.borderWidth = 0.5
        } else {
            userNameLabel.text = message.userName
            userNameLabel.textColor = chatUserColor(for: message.userName)
            messageLabel.text = message.message
            messageLabel.textColor = UIColor(white: 0.9, alpha: 1.0)
            messageLabel.font = UIFont.preferredFont(forTextStyle: .caption1)

            stackView.addArrangedSubview(userNameLabel)
            stackView.addArrangedSubview(messageLabel)

            bubbleView.backgroundColor = UIColor.black.withAlphaComponent(AppConstants.PlayerUI.Opacity.overlayMedium)
            bubbleView.layer.borderColor = UIColor.white.withAlphaComponent(0.2).cgColor
            bubbleView.layer.borderWidth = 0.5
        }
    }
    
    private func chatUserColor(for userName: String) -> UIColor {
        let colors: [UIColor] = [
            .systemBlue, .systemGreen, .systemOrange, .systemPurple,
            .systemPink, .systemCyan, .systemMint, .systemIndigo
        ]
        let index = abs(userName.hashValue) % colors.count
        return colors[index]
    }
}

// MARK: - Capsule Cell (单行，胶囊圆角)

final class ChatBubbleCapsuleCell: ChatBubbleBaseCell {
    static let reuseIdentifier = "ChatBubbleCapsuleCell"
    
    override func configure(with message: ChatMessage) {
        super.configure(with: message)
        // ★ 关键:configure 时 bounds.height 还是 0,不能靠它算圆角。
        // 先按字体度量给一个「稳定的非零」估算圆角,保证即使后续 layoutSubviews
        // 没能以正确高度回调(全屏切换后的首个布局 pass 常见 height≈0,且不保证再回调,
        // 要手动滚动才修),气泡也始终是胶囊而非直角。
        bubbleView.layer.cornerRadius = Self.estimatedSingleLineHeight / 2
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 有真实高度时精修成精确胶囊;height==0 的测量 pass 跳过,保留 configure 的估算值,
        // 绝不把 cornerRadius 写回 0(那正是切换后变直角的根因)。
        let h = bubbleView.bounds.height
        guard h > 0 else { return }
        bubbleView.layer.cornerRadius = h / 2
    }

    /// 单行气泡的稳定高度估算:caption1 行高 + 上下各 8pt 堆栈内边距。随 Dynamic Type 变化。
    /// 估算略大无妨——CALayer 会把 cornerRadius 钳到 min(w,h)/2,渲染出来仍是完美胶囊。
    private static var estimatedSingleLineHeight: CGFloat {
        ceil(UIFont.preferredFont(forTextStyle: .caption1).lineHeight) + 8 * 2
    }
}

// MARK: - Rounded Cell (多行，固定圆角)

final class ChatBubbleRoundedCell: ChatBubbleBaseCell {
    static let reuseIdentifier = "ChatBubbleRoundedCell"

    private static let cornerRadius: CGFloat = 12

    override func configure(with message: ChatMessage) {
        super.configure(with: message)
        bubbleView.layer.cornerRadius = Self.cornerRadius
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 重申固定圆角,防止全屏切换的布局/复用过程中 layer 圆角被重置成直角。
        bubbleView.layer.cornerRadius = Self.cornerRadius
    }
}

// MARK: - UIFont Extension

private extension UIFont {
    func withWeight(_ weight: UIFont.Weight) -> UIFont {
        let descriptor = fontDescriptor.addingAttributes([.traits: [UIFontDescriptor.TraitKey.weight: weight]])
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}
