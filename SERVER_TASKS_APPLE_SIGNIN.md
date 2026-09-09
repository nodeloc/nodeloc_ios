# 服务端待办 —— 原生 Sign in with Apple

iOS 端已经实现了原生 Apple 登录,但**需要一个服务端端点**才能生效。端点不存在时客户端会**自动回落到现有的网页 OAuth 流程**,所以这份文档没做完也不影响上架。

---

## 1. 为什么必须新增端点

Discourse 的 Apple 登录是标准 OmniAuth OAuth2 策略
(`plugins/discourse-apple-auth/lib/omniauth_apple.rb`):

```ruby
class Apple < OmniAuth::Strategies::OAuth2
  option :client_options, site: "https://appleid.apple.com",
         authorize_url: "/auth/authorize", token_url: "/auth/token"
  uid { id_token_info["sub"] }
```

它只有 `callback_phase`,整个流程由**浏览器往返**驱动。原生登录拿到的是
`ASAuthorizationAppleIDCredential`(identity token + authorization code),
**没有任何现成入口可以提交**。所以需要一个接收并验签 identity token 的端点。

---

## 2. 端点契约(客户端已按此实现)

```
POST /mobile/auth/apple.json
Content-Type: application/json
```

请求体:

```json
{
  "identity_token": "<Apple 返回的 JWT>",
  "nonce": "<客户端生成的原始 nonce,未哈希>",
  "authorization_code": "<可选>",
  "email": "<仅首次授权时有>",
  "full_name": "<仅首次授权时有>"
}
```

成功响应:**下发 Discourse 的会话 cookie(`_t`)**,body 至少返回

```json
{ "success": true, "username": "someone" }
```

> 客户端读的是 cookie,不是 body 里的 token —— 它复用了用户名密码登录后
> 那套完全相同的会话接管逻辑(`completeProviderLogin` 的尾部)。所以只要
> 设置了 `_t`,后续行为与网页登录完全一致。

失败响应:

| 情况 | 状态码 | 客户端行为 |
|---|---|---|
| 端点未部署 | 404 / 501 | **自动回落到网页 OAuth 流程**(静默,用户无感) |
| token 验签失败 / nonce 不匹配 | 401 | 提示登录失败 |
| **需要先登录再绑定**(见第 6 节) | **409** | 提示「请先用原有方式登录,再到设置里绑定」 |
| 其它 | 4xx / 5xx | 提示登录失败 |

---

## 3. 验签步骤(逐条,不能省)

1. 取 Apple 公钥:`GET https://appleid.apple.com/auth/keys`(JWKS,应缓存)
2. 用 `kid` 选中公钥,验证 JWT 签名(RS256)
3. 校验 claim:
   - `iss == "https://appleid.apple.com"`
   - `exp` 未过期
   - **`aud` —— 见下面第 4 节,这里最容易错**
   - `nonce` 等于**请求体里 nonce 的 SHA256 十六进制小写**
     (客户端发原始值,Apple 存的是哈希值)
4. `sub` 即 Apple 的稳定用户标识

---

## 4. 【坑一】`aud` 与网页流程不同

| 流程 | `aud` |
|---|---|
| 网页 OAuth(现有) | **Services ID**(插件里配的 `apple_client_id`) |
| 原生(新增) | **App 的 bundle ID** = `com.nodeloc.app` |

端点必须**同时接受这两个 audience**,否则原生 token 一律被判无效。

---

## 5. 【坑二】`sub` 是否与网页流程一致 —— 上线前必须实测

按 `sub` 去找已有绑定:

```ruby
UserAssociatedAccount.find_by(provider_name: "apple", provider_uid: sub)
```

Apple 的 `sub` 在**同一 team** 内稳定,但前提是那个 Services ID 配置在
**同一个 primary App ID** 之下。如果不是:

> 已经用网页版 Apple 登录过的用户,改用原生登录会拿到**不同的 `sub`** →
> 匹配不到绑定 → **给他新建一个账号**,原账号的帖子、积分、私信全部对不上。

**这是丢账号级别的事故,不能想当然。** 上线前用一个**已经通过网页版 Apple
登录过的真实账号**验证:

```ruby
# 记下该账号现有的 provider_uid
UserAssociatedAccount.where(provider_name: "apple").pluck(:user_id, :provider_uid)
```

然后用同一 Apple ID 走原生流程,打印端点收到的 `sub`,**必须与上面一致**。
不一致就不要上线原生流程 —— 保持网页 OAuth 即可,客户端会自动回落。

配置检查:Apple Developer → Identifiers → 那个 Services ID → 确认
"Primary App ID" 指向 `com.nodeloc.app`。

---

## 6. 【核心】同一个端点,四种语义 —— 由「有没有会话」决定

这是整份文档最容易做错的部分。**端点的行为必须取决于请求是否携带有效会话**,
否则老用户会被判成新用户。

| 会话 | `sub` 已绑定? | 应该做什么 | 返回 |
|---|---|---|---|
| **有**(已登录) | 未绑定 | **绑到当前登录的账号** | 200 |
| **有** | 已绑定给**当前**用户 | 幂等,什么都不做 | 200 |
| **有** | 已绑定给**别人** | 拒绝,不要改绑 | 409 |
| **无** | 已绑定 | 登录该用户 | 200 + `_t` cookie |
| **无** | 未绑定 | 见下面 6.1 | 200 或 **409** |

客户端已经按这张表实现:

- 「设置 → 关联账户 → 绑定 Apple」**带会话**发同一个请求 → 走前三行
- 登录页的 Apple 按钮**先清掉 cookie 再发** → 走后两行

### 6.1 未登录 + `sub` 未绑定 —— 建号还是拒绝?

这一格决定老用户会不会被复制一份。规则:

1. Apple 给了真实邮箱,且**匹配到已有用户** → **返回 409**,不要自动绑定也
   不要建号。客户端会提示「这个 Apple ID 还没有绑定账号。请先用原有方式登录,
   再到「设置 → 关联账户」里绑定。」
   
   > 自动按邮箱绑定是**不能做的**:任何人只要注册一个同名邮箱的 Apple ID 就能
   > 接管别人的论坛账号。必须由已登录的本人确认。

2. 邮箱匹配不到,或用户选了 **「隐藏我的邮箱」**(`@privaterelay.appleid.com`)
   → 这是真的新用户,**建号**并写入
   `UserAssociatedAccount(provider_name: "apple", provider_uid: sub)`

> 私密转发邮箱使得「按邮箱找回老账号」对相当一部分用户根本不可行 —— 这正是
> 为什么 App 里必须有那个**主动绑定**入口,而不能只靠登录时猜。

### 6.2 其它

- `email` / `full_name` **只有首次授权会给**,后续为空。建号时用得上,之后不要
  依赖它们
- 建议复用 Discourse 自己的建号路径(`UserAuthenticator` / `omniauth` 那套的
  下游逻辑),避免绕过站点的注册校验、邮箱冲突处理与审核设置 —— 它对「邮箱已
  被占用」本来就有成熟的处理

---

## 7. 客户端已完成的部分(供对照)

| 项 | 实现 |
|---|---|
| 原生按钮 | `SignInWithAppleButton`(Apple 官方组件,文案与配色自动合规) |
| nonce | 32 字节随机 → 原始值发给服务端,SHA256 发给 Apple |
| 请求 | `DiscourseClient.nativeAppleLogin(...)` |
| 会话接管 | `DiscourseLogin.completeNativeAppleLogin()`,与网页登录共用同一尾部 |
| 回落 | 端点 404/501 时自动改走 `/auth/apple` 网页流程 |
| entitlement | `com.apple.developer.applesignin` 已加入 `nodeloc.entitlements` |

**还需要在 Apple Developer 后台为 App ID `com.nodeloc.app` 勾选
"Sign in with Apple" capability** —— 这一步在网页后台,我无法代做。没勾的话
原生请求会在设备上直接失败(客户端会回落到网页流程,不会崩)。
