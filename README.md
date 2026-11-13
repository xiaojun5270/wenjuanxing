# 问卷星问卷自动填写 / 提交教程

> iPhone 版本已放在 [`ios/`](ios/)；GitHub Actions 会构建可供二次签名的无证书 IPA。
> 具体构建和安装方式见 [`ios/README.md`](ios/README.md)。

以 <https://v.wjx.cn/vm/tghWxdt.aspx>（标题「活动」，题目 1.工号 2.姓名）为例，
把一个问卷星的提交请求完全拆开，然后给出两套可以直接跑的脚本：

| 文件 | 做什么 | 依赖 |
| --- | --- | --- |
| [`wjx_http_submit.py`](wjx_http_submit.py) | 纯 HTTP：GET 页面拿参数 → POST 提交，不启浏览器 | `requests` |
| [`wjx_browser_submit.py`](wjx_browser_submit.py) | 浏览器自动化：填表、点提交，遇到验证码由人点一下 | `playwright` |
| [`capture_request.py`](capture_request.py) | 抓包器：你自己点提交，它把 `processjq.ashx` 请求打印出来 | `playwright` |

两套都在这台机器上对着真实问卷跑通过（结果见文末“实测记录”）。

**最快上手**（依赖已经装在 `vendor\` 里，`run.bat` 会用 DSH 自带的 python）：

```bat
:: 只看请求，不发
run.bat wjx_http_submit.py --id A001 --name 张三

:: 真提交
run.bat wjx_http_submit.py --id A001 --name 张三 --send
```

想用自己的 python 就 `pip install -r requirements.txt`，然后直接 `python wjx_http_submit.py ...`。

---

## 1. 问卷长什么样

页面 HTML 里只有一个 `form`，两道文本题：

```html
<form id="form1" method="post" action="https://v.wjx.cn/joinnew/processjq.ashx?shortid=tghWxdt">
```

```html
<div class='field ui-field-contain' topic='1' id='div1' req='1' type='1'>
    <div class='field-label'>... <div class='topichtml'>工号：</div></div>
    <input type='text' id='q1' name='q1' .../>
</div>
<div class='field ui-field-contain' topic='2' id='div2' req='1' type='1'>
    <div class='field-label'>... <div class='topichtml'>姓名</div></div>
    <input type='text' id='q2' name='q2' .../>
</div>

<input type="hidden" value="2026/11/13 11:27:59" id="starttime" name="starttime" />
```

`topic` 就是题目号，`type` 是题型（1=单行文本，2=多行文本，3=单选，4=多选…），
`req='1'` 表示必答。这两题的答案就是两个字符串。

页面头部的内联 JS 里还有几个关键变量：

```js
var jqnonce = "ce13fed6-7173-4c8d-a699-f6a5325d833a";   // 每次打开都不同
var rndnum  = "975607815.66188640";
var newAward = 1;
var captchaType = '2';        // 阿里云智能验证
var captchaSceneid = "q0hcfsca";
```

---

## 2. 抓包：一次提交只发两个请求

用 DevTools 的 Network 面板（或者本仓库的 `capture_request.py`：打开页面后你手动填
一次、点提交，它把请求原样打印出来）抓一次真实提交，得到：

**① GET 问卷页** `https://v.wjx.cn/vm/tghWxdt.aspx` → 200，其中响应头带
`acw_tc` / `.ASPXANONYMOUS` / `SERVERID` 等 cookie，后面 POST 要带上同一套 cookie。

**② POST 提交**（真正交答卷的那一个）：

```
POST https://v.wjx.cn/joinnew/processjq.ashx?
       shortid=tghWxdt
      &starttime=2026%2F11%2F13%2011%3A52%3A49
      &cst=1794541973644
      &submittype=1
      &ktimes=3
      &rn=975607815.55354094
      &jcn=%E8%87%A9%E5%8A%AB%E5%8C%95%E6%B5%88%E8%AF%96
      &nw=1&jwt=4&jpm=70
      &capt=2
      &t=1794541973648
      &wxfs=100
      &jqnonce=bfb07a48-94f2-4df8-8237-4b8815f92eda
      &jqsign=aea34b7%3B.%3A7e1.7ge%3B.%3B104.7a%3B%3B26e%3A1fgb

Content-Type: application/x-www-form-urlencoded; charset=UTF-8
X-Requested-With: XMLHttpRequest
Referer: https://v.wjx.cn/vm/tghWxdt.aspx

submitdata=1%24TEST002%7D2%24%E8%87%AA%E5%8A%A8%E5%8C%96%E6%B5%8B%E8%AF%95&sceneId=q0hcfsca
```

注意：**表单数据全在 body 里，其余全在 query 上**。`submitdata` 解码后就是
`1$TEST002}2$自动化测试`。

返回是一段纯文本：

```
10〒/wjx/join/complete.aspx?activityid=tghWxdt&joinid=128264299205&sojumpindex=259&comsign=C4BE...
```

开头 `10` 表示成功（`〒` 是分隔符），后半段就是结果页地址，`sojumpindex` 是答卷序号。

### 参数表

| 参数 | 值 | 说明 |
| --- | --- | --- |
| `shortid` | `tghWxdt` | 问卷短 id，就是网址里的那段 |
| `starttime` | `2026/11/13 11:52:49` | 页面里 `#starttime` 的值，**必须用 encodeURIComponent 编码**（`/`→`%2F`，空格→`%20`） |
| `cst` | 毫秒时间戳 | 客户端提交时间 |
| `submittype` | `1` | 1=提交，3=翻页，6=预览 |
| `ktimes` | `3` | 页面里的“交互次数”（鼠标划过题目会 +1），签名要用同一个数 |
| `rn` | `975607815.55354094` | 页面里的 `rndnum` |
| `jcn` | 异或后的姓名 | 姓名答案再 `dataenc` 一遍，服务端拿它做去重/风控 |
| `nw`/`jwt`/`jpm` | `1`/`4`/`70` | 答题后抽奖相关的参数，值来自页面脚本 |
| `capt` | `2` | 该问卷开的是阿里云智能验证 |
| `t` | 毫秒时间戳 | 防缓存 |
| `jqnonce` | UUID | 页面里的 `jqnonce` |
| `jqsign` | `dataenc(jqnonce)` | 见下 |
| body `submitdata` | `1$工号}2$姓名` | 答案串 |
| body `sceneId` | `q0hcfsca` | 阿里云验证码场景 id |

---

## 3. `submitdata` 的拼法

题目之间用 `}` 连接，题号和答案之间用 `$` 连接，按题目号升序：

```
1$A001}2$张三
```

这 6 个字符是页面里的分隔符（`spChars = ["$","}","^","|","!","<"]`），所以答案里
如果出现它们，页面会先替换成“长得像”的字符，避免服务端切错：

| 原字符 | 替换成 |
| --- | --- |
| `$` | `ξ` |
| `}` | `｝` |
| `^` | `ˆ` |
| `\|` | `¦` |
| `!` | `！` |
| `<` | `＜` |

文本答案还会 `trim()` 一次。空着的非必答题会被写成 `(跳过)`。

---

## 4. `jqsign` 签名

页面里就这么两行：

```js
function dataenc(e){ for(var t=ktimes%10,i=(0==t&&(t=1),[]),n=0;n<e.length;n++){
        var a=e.charCodeAt(n)^t; i.push(String.fromCharCode(a)) } return i.join("") }
o += "&jqnonce=" + encodeURIComponent(jqnonce);
o += "&jqsign="  + encodeURIComponent(dataenc(jqnonce));
```

也就是：把 `jqnonce` 的每个字符和 `ktimes % 10`（为 0 时用 1）做异或，再
`encodeURIComponent`。`ktimes` 是页面里被鼠标事件累加的一个计数，脚本里随便给一个
自然点的值（3~6）就行，但 **URL 里的 `ktimes` 和签名用的那个数必须一致**。

Python 版：

```python
def dataenc(text, ktimes):
    key = ktimes % 10 or 1
    return "".join(chr(ord(c) ^ key) for c in text)
```

---

## 5. 返回码

| 返回 | 含义 | 怎么办 |
| --- | --- | --- |
| `10〒...complete.aspx...` | 成功 | 取后半段当结果页，`sojumpindex` 是序号 |
| `7〒需要安全校验，请重新提交！` | 风控要求先过阿里云验证 | 浏览器方案，人工点一下验证码 |
| `22〒请输入验证码` | 参数不全 / 打开页面后提交太快 | 补齐参数；停 5~10 秒再发 |
| `3〒...` / 中文提示 | 题目校验不通过（必答没填、格式不对…） | 看提示改答案 |

> 实测：只发“最小参数集合”（`shortid/starttime/submittype/ktimes/cst/t/jqnonce/jqsign`）
> 一定会被挡；打开页面后 0.4 秒内就 POST 也会被挡（回 `22`）。把参数补齐 + 停留 6 秒，
> 连续跑 4 次都直接成功。

---

## 6. 方案 A：纯 HTTP

```bash
pip install requests        # 用 run.bat 的话可以跳过，vendor\ 里已经有了

# 先干跑（只打印请求，不发）
python wjx_http_submit.py --id A001 --name 张三

# 真提交
python wjx_http_submit.py --id A001 --name 张三 --send

# 更稳：停 10 秒再交
python wjx_http_submit.py --id A001 --name 张三 --send --dwell 10
```

脚本做的事：

1. `GET` 问卷页，正则取出 `starttime` / `jqnonce` / `rndnum` / `newAward`；
2. 用 `div.field` 的 `topic` + `topichtml` 把题目和题干解析出来（换问卷也能直接用）；
3. 按 `题目号$答案` 拼 `submitdata`，算 `jcn`、`jqsign`；
4. 停 `--dwell` 秒，`POST` 到 `processjq.ashx`，解析 `10` / `7` / `22`。

> `jwt=4`、`jpm=70`、`wxfs=100` 这几个抽奖/来源参数是从这个问卷的页面脚本里抓的。
> 问卷换了配置它们可能变，用 DevTools 看一眼 POST 的 query 更新即可；
> 其余参数都是页面里现成的。

---

## 7. 方案 B：浏览器自动化（遇到验证码时用）

```bash
pip install playwright
python -m playwright install chromium          # 或者用本机已有浏览器：--channel chrome / msedge

python wjx_browser_submit.py --id A001 --name 张三
python wjx_browser_submit.py --id A001 --name 张三 --fill-only     # 只填不交，调试用
```

脚本会：

1. 打开问卷，等 JS 渲染完（自动关掉“您之前已经回答了部分题目，是否继续上次回答”弹窗）；
2. 按题干里含「工号」「姓名」找到 `div.field`，逐字输入（`delay=70ms`，像真人）；
3. 点 `#ctlNext`（提交按钮）；
4. 轮询：网址出现 `complete` → 成功截图 `success.png`；出现阿里云验证浮层 →
   控制台提示“请手动完成验证”，人点一下/拖一下后页面自动带 `captchaVerifyParam`
   重新提交，脚本继续等；`#ValError` 有报错 → 打印并截图 `error.png`。

启动浏览器失败（比如 `spawn UNKNOWN`、企业策略禁了子进程）时，可以先自己开一个带
调试端口的 Chrome，再让脚本连过去：

```bash
"C:\Program Files\Google\Chrome\Application\chrome.exe" --remote-debugging-port=9333 ^
    --user-data-dir=D:\tmp\chrome-prof about:blank
python wjx_browser_submit.py --id A001 --name 张三 --cdp http://127.0.0.1:9333
```

> 本机验证时用的就是这种 CDP 方式（沙箱里 playwright 无法用 `--remote-debugging-pipe`
> 启动浏览器，换成 TCP 端口就正常了）。

跑起来就是这样：

![脚本填好的表单](debug_form.png)

![提交成功的页面](success.png)

---

## 8. 换成别的问卷怎么改

1. 把 `wjx_http_submit.py` 顶部的 `SHORTID` 换成新问卷网址里的那段（`v.wjx.cn/vm/XXXX.aspx`）；
2. 打开问卷 → F12 → Network → 点提交 → 找 `processjq.ashx` 那条，比对 query 参数；
3. 题型不同，`submitdata` 里的答案格式也不同（页面里 `getAnswer()` 的 `case "1".."11"`）：

| 题型 | `type` | 答案写法 |
| --- | --- | --- |
| 单行文本 | 1 | `1$文本` |
| 多行文本 | 2 | `1$文本` |
| 单选 | 3 | `1$选项序号`（从 1 开始） |
| 多选 | 4 | `1$1\|2\|3`（选项序号用 `\|` 连） |
| 下拉/量表 | 5/6 | `1$选项序号` |
| 矩阵 | 9/10 | `1$行1^列!行2^列`（`^` 分行、`!` 分列） |

4. 有跳题/逻辑判断的问卷，`submitdata` 里要带上“被跳过”的题（值写 `(跳过)`），
   或者干脆用方案 B 让页面自己算。

---

## 9. 常见问题

**Q: 需要登录吗？** 这个问卷是公开分享页，匿名即可提交；分享链接里的 `shortid`
就是全部凭据。要登录的问卷（企业版、内部问卷）另说。

**Q: 提交后能改吗？** 不能，每次 POST 都是一条新答卷（除非问卷开了“允许修改”）。

**Q: 为什么有时候会弹验证码？** 问卷星有风控：提交太快、参数不全、短时间从同一 IP
重复提交，都会升级到阿里云智能验证（`7` / `22`）。方案 B 里人工过一次验证即可。

**Q: 一个问卷能刷多少份？** 别刷。见下。

---

## 10. 实测记录

验证脚本时确实往这个真实问卷里提交了 7 条测试答卷（工号 `TEST001`、`TEST002`、
`TEST003`×3、`TEST005`、`TEST006`，姓名都是「自动化测试」），序号分别是
258、259、260、261、262、263、264。如果这个问卷是你自己建的，记得在后台把这 7 条删掉；
如果不是，请把脚本里的数据换成你自己的真实信息再跑。

---

## 11. 合规提醒

- 这个教程用于：**填自己的那一份**、测试**自己的问卷**、或者做内部工具。
- 不要用来刷量、刷抽奖、伪造他人答卷 —— 那是垃圾数据，也可能违反问卷星服务条款。
- 所以两个脚本都**没有**绕过阿里云智能验证的能力：HTTP 版撞到验证码就停下并提示你
  改用浏览器；浏览器版把验证码留给人。
