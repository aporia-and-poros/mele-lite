#if LITE
import SwiftUI

/// 切走以后（11-13）：本机版发完就退出，TA 也把这一轮回完、照常弹通知。代价是回的时候锁屏 / 灵动岛上挂一条进度，所以给个开关。
struct KeepReplyingCard: View {
    @EnvironmentObject private var theme: AppTheme
    @AppStorage(KeepReplying.key) private var on = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("切走以后").font(Typo.sans(Typo.Size.headline, .semibold)).foregroundStyle(theme.ink)
            Toggle(isOn: $on) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("切走也接着回完").font(Typo.sans(Typo.Size.body)).foregroundStyle(theme.ink)
                    Hint(text: on
                         ? String(localized: "发完消息就切走、锁屏，TA 也会把这一轮回完，回复照常弹通知。回的时候锁屏和灵动岛上会挂一条进度，回完就收掉。")
                         : String(localized: "切走以后苹果只给大约 30 秒，来不及回完的，要等你回到 App 才出来。模型回得慢、或者接了记忆库，可以打开。"))
                }
            }
            .tint(theme.accentDeep)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
    }
}
#endif
