#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
问卷星 (v.wjx.cn) 表单提交 —— 纯 HTTP 协议实现
================================================

目标问卷: https://v.wjx.cn/vm/tghWxdt.aspx   标题「活动」
题目: 1. 工号（文本）  2. 姓名（文本）  两题都必答

一次完整提交 = 1 个 GET + 1 个 POST
-----------------------------------
GET  https://v.wjx.cn/vm/tghWxdt.aspx
     页面里藏着 4 个要用的值：
       <input id="starttime" value="2026/11/13 11:52:49">   → starttime（作答开始时间）
       var jqnonce = "bfb07a48-94f2-..."                     → 一次性随机串，用来签名
       var rndnum  = "975607815.64956480"                    → rn
       var newAward = 1                                      → nw

POST https://v.wjx.cn/joinnew/processjq.ashx?<query>
     query 参数（实测缺一个就可能被 7 / 22 挡回来，按页面实际顺序发最稳）:
       shortid=tghWxdt         问卷短 id
       starttime=2026%2F...    上面那个时间（encodeURIComponent 后 "/" 也变 %2F）
       cst=<毫秒>               客户端提交时间
       submittype=1             1=提交
       ktimes=<次数>            页面里的“交互次数”，签名要用同一个值
       rn=<rndnum>              页面里的随机数
       jcn=<dataenc(姓名)>      姓名再异或一遍，服务端拿它做去重/风控
       nw=1 / jwt=4 / jpm=70 / wxfs=100
                                抽奖（答题后抽奖）相关的固定参数，值来自页面脚本；
                                问卷换了抽奖配置的话，从浏览器抓包更新即可
       capt=2                   该问卷开的是阿里云智能验证
       t=<毫秒>                 时间戳，防缓存
       jqnonce=<nonce>
       jqsign=<dataenc(nonce)>  见下面“签名”

POST body（application/x-www-form-urlencoded）:
       submitdata=1%24<工号>%7D2%24<姓名>&sceneId=q0hcfsca
       解码后是  submitdata=1$工号}2$姓名

答案串格式
----------
   题目号 + "$" + 答案，多题之间用 "}" 连接（页面里 spChars = ["$","}","^","|","!","<"]）。
   答案里的这几个字符会被替换成人眼看着一样的字符（replace_specialChar）：
       $→ξ   }→｝   ^→ˆ   |→¦   !→！   <→＜
   文本题的答案会 trim 一下。

签名 dataenc
------------
   function dataenc(s){ var k = ktimes%10 || 1;
                        return [...s].map(c => c.charCodeAt(0)^k).join(""); }
   也就是逐字符异或 ktimes%10（结果为 0 时按 1 算），页面就是这么算 jqsign 的。

返回体
------
   10〒/wjx/join/complete.aspx?activityid=...&joinid=...&sojumpindex=...
        成功，第二段是结果页地址（sojumpindex 就是答卷序号）
   7〒需要安全校验，请重新提交！      风控要求先过阿里云智能验证 → 用浏览器方案
   22〒请输入验证码                  参数不全 / 触发验证码
   其它                               题目校验失败，第二段是中文提示

用法
----
   python wjx_http_submit.py --id A001 --name 张三              # 只打印请求（dry-run）
   python wjx_http_submit.py --id A001 --name 张三 --send       # 真的提交
   python wjx_http_submit.py --id A001 --name 张三 --send --dwell 10
                                                               # 停留 10 秒再交，更稳
   python wjx_http_submit.py --id A001 --name 张三 --send --repeat 3
                                                               # 连续提交 3 次（自测用）

两个容易踩的坑（都实测过）
--------------------------
1. 打开页面后马上 POST（几百毫秒）会被判成机器：返回 7〒需要安全校验 或 22〒请输入
   验证码。停 5~10 秒再发就正常（脚本 --dwell 默认 6 秒，是实测可用的值）。
2. 参数不能只发“最短集合”：短集合 100% 被挡回来，把页面真实会发的参数（尤其是
   jcn、rn、nw/jwt/jpm/wxfs）都带上才拿得到 10。

⚠ 请只用来提交自己的答卷 / 自己问卷的测试数据。批量刷答卷属于垃圾数据，也可能违反
   问卷星的服务条款，本脚本没有、也不应该加绕过验证码的能力。
"""
from __future__ import annotations

import argparse
import random
import re
import sys
import time
from urllib.parse import quote

try:
    import requests
except ImportError:  # pragma: no cover
    sys.exit("需要 requests:  pip install requests")

SHORTID = "tghWxdt"
PAGE_URL = f"https://v.wjx.cn/vm/{SHORTID}.aspx"
SUBMIT_URL = f"https://v.wjx.cn/joinnew/processjq.ashx?shortid={SHORTID}"
SCENE_ID = "q0hcfsca"                     # 阿里云验证码场景 id（页面里 captchaSceneid）
USER_AGENT = (
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/157.0.0.0 Safari/537.36"
)

# 答案里的分隔符 → 长得像的替代字符（页面 replace_specialChar）
ESCAPE_MAP = [("$", "ξ"), ("}", "｝"), ("^", "ˆ"), ("|", "¦"), ("!", "！"), ("<", "＜")]


# --------------------------------------------------------------------------- #
# 编码 / 签名
# --------------------------------------------------------------------------- #
def encode_uri_component(text: str) -> str:
    """等价于 JS 的 encodeURIComponent()。"""
    return quote(str(text), safe="-_.!~*'()")


def dataenc(text: str, ktimes: int) -> str:
    """等价于页面里的 dataenc()：逐字符异或 ktimes%10（0 视为 1）。"""
    key = ktimes % 10 or 1
    return "".join(chr(ord(c) ^ key) for c in text)


def escape_answer(value: str) -> str:
    """等价于 replace_specialChar()。"""
    for src, dst in ESCAPE_MAP:
        value = value.replace(src, dst)
    return value


# --------------------------------------------------------------------------- #
# 解析问卷页
# --------------------------------------------------------------------------- #
def tag_value(html: str, elem_id: str) -> str:
    """取 <input id="xxx" ... value="yyy"> 的 value（属性顺序无关）。"""
    m = re.search(r'<input[^>]*id="%s"[^>]*>' % re.escape(elem_id), html)
    if not m:
        return ""
    v = re.search(r'value="([^"]*)"', m.group(0))
    return v.group(1) if v else ""


def js_var(html: str, name: str) -> str:
    m = re.search(r'var\s+%s\s*=\s*"?([^";\r\n]*)"?' % re.escape(name), html)
    return m.group(1).strip() if m else ""


def parse_questions(html: str) -> list[dict]:
    """抓出每个 div.field 的 topic / type / 题干 / 是否必答。"""
    questions = []
    opens = list(re.finditer(r"<div class='field[^>]*topic='(\d+)'[^>]*>", html))
    for i, m in enumerate(opens):
        open_tag = m.group(0)
        end = opens[i + 1].start() if i + 1 < len(opens) else html.find("</fieldset>", m.start())
        block = html[m.end():end]
        qtype = re.search(r"type='(\d+)'", open_tag)
        label = re.search(r"<div class='topichtml'>(.*?)</div>", block, re.S)
        title = re.sub(r"<[^>]+>", "", label.group(1)).strip() if label else ""
        questions.append({
            "topic": int(m.group(1)),
            "type": int(qtype.group(1)) if qtype else 0,
            "title": title,
            "required": bool(re.search(r"req='1'", open_tag)),
        })
    return questions


def find_name_topic(questions: list[dict]) -> int | None:
    """姓名题：jcn 参数要用它的答案。"""
    for q in questions:
        if q["type"] == 1 and any(k in q["title"] for k in ("姓名", "名字", "NAME", "Name")):
            return q["topic"]
    return None


# --------------------------------------------------------------------------- #
# 组请求
# --------------------------------------------------------------------------- #
def build_submitdata(answers: dict[int, str]) -> str:
    """{1: 'A001', 2: '张三'} -> '1$A001}2$张三'"""
    return "}".join(f"{t}${escape_answer(v)}" for t, v in sorted(answers.items()))


def build_request(html: str, answers: dict[int, str], ktimes: int,
                  rndnum: str | None = None) -> tuple[str, str]:
    """返回 (POST URL, POST body)。"""
    starttime = tag_value(html, "starttime")
    jqnonce = js_var(html, "jqnonce")
    if not (starttime and jqnonce):
        raise RuntimeError("页面结构变了：找不到 starttime / jqnonce")

    now_ms = int(time.time() * 1000)
    jcn_topic = find_name_topic(parse_questions(html))
    jcn = dataenc(answers.get(jcn_topic, ""), ktimes) if jcn_topic else ""

    params = [
        ("starttime", starttime),
        ("cst", str(now_ms)),
        ("submittype", "1"),
        ("ktimes", str(ktimes)),
        ("rn", rndnum if rndnum is not None else js_var(html, "rndnum")),
        ("jcn", jcn),
        ("nw", js_var(html, "newAward") or "1"),
        ("jwt", "4"),
        ("jpm", "70"),
        ("capt", "2"),
        ("t", str(now_ms + random.randint(1, 9))),
        ("wxfs", "100"),
        ("jqnonce", jqnonce),
        ("jqsign", dataenc(jqnonce, ktimes)),
    ]
    url = SUBMIT_URL + "&" + "&".join(f"{k}={encode_uri_component(v)}" for k, v in params)
    body = ("submitdata=" + encode_uri_component(build_submitdata(answers))
            + f"&sceneId={SCENE_ID}")
    return url, body


# --------------------------------------------------------------------------- #
# 提交
# --------------------------------------------------------------------------- #
def submit_once(session: requests.Session, answers: dict[int, str],
                dry_run: bool, dwell: float = 6.0) -> int:
    started = time.time()
    html = session.get(PAGE_URL, timeout=30).text
    ktimes = random.randint(3, 6)          # 页面里鼠标划过题目才会增加，3~6 很自然

    # 服务端会算“作答时长”。打开页面后立刻 POST（<1 秒）会被判成机器，回 7/22 要求验证码；
    # 停几秒再发就正常。默认 6 秒是实测能用住的值，想更稳可以给 10 秒。
    wait = dwell - (time.time() - started)
    if wait > 0:
        time.sleep(wait)

    url, body = build_request(html, answers, ktimes)

    if dry_run:
        print("POST", url)
        print("Body:", body)
        print("submitdata 解码后:", build_submitdata(answers))
        print("[dry-run] 没发送，加 --send 才会真的提交\n")
        return 0

    r = session.post(url, data=body, timeout=30, headers={
        "Referer": PAGE_URL,
        "Origin": "https://v.wjx.cn",
        "Accept": "text/plain, */*; q=0.01",
        "Content-Type": "application/x-www-form-urlencoded; charset=UTF-8",
        "X-Requested-With": "XMLHttpRequest",
    })
    text = r.text.strip()
    head, _, rest = text.partition("〒")

    if head == "10":
        print(f"✅ 提交成功  答卷序号/结果页: {rest}")
        return 0
    if head == "7":
        print("⚠ 触发风控：服务端要求「阿里云智能验证」。")
        print("  请改用 wjx_browser_submit.py（浏览器里点一下验证码即可）。")
        return 7
    print(f"❌ 失败（{r.status_code}）: {text}")
    return 1


def main() -> None:
    ap = argparse.ArgumentParser(description="问卷星 tghWxdt 表单提交（HTTP 版）")
    ap.add_argument("--id", dest="emp_id", help="第 1 题 工号")
    ap.add_argument("--name", dest="emp_name", help="第 2 题 姓名")
    ap.add_argument("--answer", action="append", default=[], metavar="TOPIC=VALUE",
                    help="通用写法，如 --answer 1=A001 --answer 2=张三")
    ap.add_argument("--send", action="store_true", help="真的发送 POST（默认只打印）")
    ap.add_argument("--dwell", type=float, default=6.0,
                    help="打开页面后停留多少秒再提交（模拟作答耗时，太快会被要求验证码）")
    ap.add_argument("--repeat", type=int, default=1, help="连续提交几次（自测用，默认 1）")
    args = ap.parse_args()

    answers: dict[int, str] = {}
    for item in args.answer:
        k, _, v = item.partition("=")
        answers[int(k)] = v
    if args.emp_id:
        answers[1] = args.emp_id
    if args.emp_name:
        answers[2] = args.emp_name
    if not answers:
        ap.error("至少给一个答案，例如 --id A001 --name 张三")

    session = requests.Session()
    session.headers.update({"User-Agent": USER_AGENT,
                            "Accept-Language": "zh-CN,zh;q=0.9"})

    code = 0
    for i in range(max(1, args.repeat)):
        if i:
            print()
        code = submit_once(session, answers, dry_run=not args.send, dwell=args.dwell)
        if code:
            break
    sys.exit(code)


if __name__ == "__main__":
    main()
