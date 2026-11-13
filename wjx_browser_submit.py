#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
问卷星 (v.wjx.cn) 表单提交 —— 浏览器自动化版（推荐，能真正提交成功）
====================================================================

背景
----
wjx_http_submit.py 用纯 HTTP 就能提交成功（GET 页面 → POST processjq.ashx）。
但只要有一环不对 —— 参数不全、打开页面后几十毫秒就提交、同一 IP 短时间里交太多次 ——
服务端就会回
    "7〒需要安全校验，请重新提交！"
    "22〒请输入验证码"
这时页面会弹出阿里云「智能验证」(captchaType=2)，要求一个 captchaVerifyParam 一次性
令牌。该令牌只能由阿里云验证码 SDK 在真浏览器里生成，纯 HTTP 拼不出来。

所以这个脚本是“兜底方案”：让真浏览器自己跑完页面 JS，脚本只负责
    1) 打开问卷   2) 按题目标题填答案   3) 点“提交”
如果弹出智能验证，由人点一下 / 拖一下，页面会自动带着令牌重新提交成功。
调试、只想跑一次、或者服务端开始要求验证码时，用它最稳。

安装
----
    pip install playwright
    python -m playwright install chromium        # 可选：不给 --channel 时用自带内核

用法
----
    python wjx_browser_submit.py --id A001 --name 张三
    python wjx_browser_submit.py --id A001 --name 张三 --fill-only      # 只填不提交
    python wjx_browser_submit.py --id A001 --name 张三 --channel msedge # 用本机 Edge
    python wjx_browser_submit.py --id A001 --name 张三 --cdp http://127.0.0.1:9333
                                                                        # 连接已开的 Chrome

出现滑块时，脚本会在控制台提示，请在浏览器窗口里完成验证；完成后页面自动继续提交，
脚本会等结果页出现并打印最终网址、保存截图。
"""
from __future__ import annotations

import argparse
import sys
import time

try:
    from playwright.sync_api import sync_playwright, Error as PlaywrightError
except ImportError:  # pragma: no cover
    sys.exit("需要 playwright:  pip install playwright")

URL = "https://v.wjx.cn/vm/tghWxdt.aspx"


# --------------------------------------------------------------------------- #
# 打开浏览器
# --------------------------------------------------------------------------- #
def open_page(p, channel: str | None, headless: bool, cdp: str | None):
    """返回 (browser, page, owns_browser)。"""
    if cdp:
        browser = p.chromium.connect_over_cdp(cdp)
        context = browser.contexts[0] if browser.contexts else browser.new_context()
        page = context.pages[0] if context.pages else context.new_page()
        # 用 CDP 连别人的浏览器时，顺手把自动化特征抹掉一点
        try:
            page.add_init_script(
                "Object.defineProperty(navigator,'webdriver',{get:()=>undefined})")
        except PlaywrightError:
            pass
        return browser, page, False

    kwargs = {"headless": headless,
              "args": ["--disable-blink-features=AutomationControlled"]}
    if channel:
        kwargs["channel"] = channel
    browser = p.chromium.launch(**kwargs)
    context = browser.new_context(locale="zh-CN", timezone_id="Asia/Shanghai",
                                  viewport={"width": 1280, "height": 900})
    return browser, context.new_page(), True


# --------------------------------------------------------------------------- #
# 页面操作
# --------------------------------------------------------------------------- #
def dismiss_resume_dialog(page) -> None:
    """同一个浏览器填过一半再打开，问卷星会弹“是否继续上次回答”，这里选择重新填写。"""
    try:
        dialog = page.locator(".layui-layer").filter(has_text="是否继续上次回答")
        if not (dialog.count() and dialog.first.is_visible()):
            return
        cancel = dialog.first.locator("a").filter(has_text="取消").first
        (cancel if cancel.count() else dialog.first.locator(".layui-layer-btn1").first).click()
        print("  已关闭“是否继续上次回答”弹窗（重新填写）")
        page.wait_for_timeout(800)
    except PlaywrightError:
        pass


def fill_field(page, title_key: str, value: str) -> bool:
    """按题目标题找到 div.field，再往它里面的输入框逐字打字。"""
    field = page.locator("div.field").filter(has_text=title_key).first
    if field.count() == 0:
        print(f"  ! 没找到题目「{title_key}」")
        return False
    box = field.locator("input[type='text'], input:not([type]), textarea").first
    box.scroll_into_view_if_needed()
    box.click()
    box.fill("")
    box.type(value, delay=70)          # 逐字输入，更像真人
    print(f"  已填写「{title_key}」= {value}")
    return True


def captcha_visible(page) -> bool:
    """阿里云智能验证浮层 / iframe 是否出现。"""
    try:
        for sel in ("#aliyunCaptcha-window", ".aliyun-captcha",
                    "#aliyunCaptcha-sliding-body", "#captchaOut iframe"):
            loc = page.locator(sel)
            if loc.count() and loc.first.is_visible():
                return True
        for frame in page.frames:
            if "aliyuncaptcha" in (frame.url or "").lower():
                return True
    except PlaywrightError:
        pass
    return False


def try_click_verify(page) -> bool:
    """点一下验证码里的“开始智能验证”（有时点一下就自动通过）。"""
    for frame in page.frames:
        if "aliyuncaptcha" not in (frame.url or "").lower():
            continue
        for sel in ("#aliyunCaptcha-btn-verify", "text=点击开始智能验证",
                    "text=Click to start verification", ".aliyun-captcha-btn"):
            try:
                loc = frame.locator(sel).first
                if loc.is_visible(timeout=800):
                    loc.click(timeout=1500)
                    print("  已点击验证码按钮，等待结果…")
                    return True
            except PlaywrightError:
                continue
    return False


def error_text(page) -> str:
    try:
        return (page.locator("#ValError").inner_text() or "").strip()
    except PlaywrightError:
        return ""


# --------------------------------------------------------------------------- #
# 主流程
# --------------------------------------------------------------------------- #
def run(emp_id: str, name: str, headless: bool, fill_only: bool,
        auto_click: bool, channel: str | None, cdp: str | None, timeout: int) -> int:
    with sync_playwright() as p:
        browser, page, owns = open_page(p, channel, headless, cdp)

        print(f"打开 {URL}")
        page.goto(URL, wait_until="domcontentloaded", timeout=60_000)
        page.wait_for_timeout(1800)                    # 等页面 JS 渲染完

        print(f"页面标题: {page.title()}")
        dismiss_resume_dialog(page)

        ok = fill_field(page, "工号", emp_id)
        ok &= fill_field(page, "姓名", name)
        if not ok:
            page.screenshot(path="debug_form.png", full_page=True)
            if owns:
                browser.close()
            return 2

        if fill_only:
            page.screenshot(path="debug_form.png", full_page=True)
            print("--fill-only：已填写、未提交，截图 debug_form.png")
            page.wait_for_timeout(1500)
            if owns:
                browser.close()
            return 0

        print("点击「提交」")
        page.click("#ctlNext")

        deadline = time.time() + timeout
        notified = False
        auto_clicked = False
        while time.time() < deadline:
            if "complete" in page.url.lower():
                print("\n✅ 提交成功")
                print("结果页:", page.url)
                page.screenshot(path="success.png", full_page=True)
                if owns:
                    browser.close()
                return 0

            if captcha_visible(page):
                if not notified:
                    print("\n⚠ 出现安全验证（阿里云智能验证）。")
                    print("  请在浏览器窗口里完成验证：点按钮，必要时拖动滑块。")
                    print("  完成后页面会自动带 captchaVerifyParam 重新提交，脚本继续等待…")
                    notified = True
                if auto_click and not auto_clicked:
                    auto_clicked = try_click_verify(page)
                page.wait_for_timeout(1500)
                continue

            err = error_text(page)
            if err and "提交" not in err:
                print("\n❌ 页面报错:", err)
                page.screenshot(path="error.png", full_page=True)
                if owns:
                    browser.close()
                return 1

            page.wait_for_timeout(500)

        print("\n⌛ 等待超时。当前网址:", page.url)
        page.screenshot(path="timeout.png", full_page=True)
        if owns:
            browser.close()
        return 3


def main() -> None:
    ap = argparse.ArgumentParser(description="问卷星 tghWxdt 表单提交（浏览器自动化）")
    ap.add_argument("--id", dest="emp_id", required=True, help="第 1 题 工号")
    ap.add_argument("--name", dest="emp_name", required=True, help="第 2 题 姓名")
    ap.add_argument("--headless", action="store_true", help="无头模式（验证码基本过不去）")
    ap.add_argument("--fill-only", action="store_true", help="只填写，不点提交")
    ap.add_argument("--auto-click", action="store_true", help="自动点验证码的“开始智能验证”")
    ap.add_argument("--channel", default="chrome",
                    help="浏览器内核: chrome / msedge / 留空用 playwright 自带 chromium")
    ap.add_argument("--cdp", default=None,
                    help="连接到已经用 --remote-debugging-port 启动的浏览器，如 http://127.0.0.1:9333")
    ap.add_argument("--timeout", type=int, default=240, help="等待结果的最大秒数")
    args = ap.parse_args()

    channel = args.channel or None
    try:
        code = run(args.emp_id, args.emp_name, args.headless, args.fill_only,
                   args.auto_click, channel, args.cdp, args.timeout)
    except PlaywrightError as exc:
        msg = str(exc)
        if channel and "channel" in msg.lower():
            print(f"[!] 没找到 {channel}，改用 playwright 自带 chromium 再试一次。")
            code = run(args.emp_id, args.emp_name, args.headless, args.fill_only,
                       args.auto_click, None, args.cdp, args.timeout)
        elif "spawn" in msg.lower() or "pipe" in msg.lower():
            print("[!] playwright 启动浏览器失败（spawn/pipe）。")
            print("    多半是沙箱/安全软件不让它开子进程。改用 CDP 方式：")
            print('    1) 先开 Chrome：chrome.exe --remote-debugging-port=9333 '
                  '--user-data-dir=D:\\tmp\\chrome-prof about:blank')
            print("    2) 再跑：python wjx_browser_submit.py --cdp http://127.0.0.1:9333 ...")
            code = 4
        else:
            raise
    sys.exit(code)


if __name__ == "__main__":
    main()
