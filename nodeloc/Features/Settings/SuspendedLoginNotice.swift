//
//  SuspendedLoginNotice.swift
//  nodeloc
//
//  App-iOS-LoginSuspended: the password was right but the account is
//  suspended. The server's sentence (until when, why), and 查看处罚和申诉,
//  which opens the account status page reading and appealing with the same
//  username and password.
//

import SwiftUI

struct SuspendedLoginNotice: View {
    let message: String
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "nosign")
                    .font(.system(size: 16, weight: .semibold))
                Text(message)
                    .font(Theme.body(14, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundStyle(AdminTone.orange.text)
            Button(action: onOpen) {
                Text(AppString("查看处罚和申诉"))
                    .font(Theme.body(15, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .background(ModPillButton.brickFill, in: Capsule())
            }
            .buttonStyle(.pressable)
            Text(AppString("会用上面填的用户名和密码核对身份。只用第三方登录、没有设过密码的账号，先用“忘记密码”设一个。"))
                .font(Theme.body(12))
                .foregroundStyle(Theme.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AdminTone.orange.fill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Makes the credentials presentable with `item:`.
struct SuspendedCredentialsBox: Identifiable {
    let credentials: AccountStatusStore.Credentials
    var id: String { credentials.login }
}
