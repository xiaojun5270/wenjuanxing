#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
问卷星「提交请求」抓包器
========================

打开问卷页，你手动填表、点提交，脚本把那条 `processjq.ashx` 请求原样打印出来
（URL 参数、请求头、body、响应），用来照着改 `wjx_http_submit.py`。
它自己不会提交任何东西。

用法
----
    python capture_request.py
    python capture_request.py --url https://v.wjx.cn/vm/xxxx.aspx
    python capture_request.py --cdp http://127.0.0.1:9333   # 连已开的 Chrome
    python capture_request.py --headless                    # 无头（看不见就别想点验证码了）

抓到一条后继续挂着，可以再提交下一条；Ctrl+C 结束。
"""
from __future__ import annotations

import argparse
import sys
from urllib.parse import parse_qsl, urlparse

try:
    from playwright.sync_api import sync_playwright
except ImportError:  # pragma: no cover
    sys.exit("需要 playwright:  pip install playwright")

DEFAULT_URL = "https://v.wjx.cn/vm/tghWxdt.aspx"


def show_request(request) -> None:
    print("\n" + "=" * 78)
    print("URL:", request.url)
    print("\n-- query --")
    for key, value in parse_qsl(urlparse(request.url).query, keep_blank_values=True):
        print(f"  {key} = {value}")
    print("\n-- headers --")
    for key, value in request.headers.items():
        print(f"  {key}: {value}")
    print("\n-- body --")
    print(" ", request.post_data)
    if request.post_data:
        print("\n-- body(decoded) --")
        for key, value in parse_qsl(request.post_data, keep_blank_values=True):
            print(f"  {key} = {value}")
    print("=" * 78)


def main() -> None:
    ap = argparse.ArgumentParser(description="抓问卷星的提交请求（不会自动提交）")
    ap.add_argument("--url", default=DEFAULT_URL, help="问卷分享页地址")
    ap.add_argument("--cdp", default=None, help="连接已启动的浏览器，如 http://127.0.0.1:9333")
    ap.add_argument("--headless", action="store_true", help="无头模式")
    args = ap.parse_args()

    with sync_playwright() as p:
        if args.cdp:
            browser = p.chromium.connect_over_cdp(args.cdp)
            context = browser.contexts[0] if browser.contexts else browser.new_context()
            page = context.pages[0] if context.pages else context.new_page()
        else:
            browser = p.chromium.launch(headless=args.headless)
            page = browser.new_context(locale="zh-CN").new_page()

        def on_request(request):
            if "processjq.ashx" in request.url:
                show_request(request)

        def on_response(response):
            if "processjq.ashx" in response.url:
                try:
                    print("\n响应:", response.status, (response.text() or "")[:500])
                except Exception:            # 页面已经跳走时拿不到 body
                    print("\n响应:", response.status)

        page.on("request", on_request)
        page.on("response", on_response)

        page.goto(args.url, wait_until="domcontentloaded")
        print("浏览器已打开，请手动填写并点「提交」。抓到请求会打印在这里，Ctrl+C 退出。")
        try:
            page.wait_for_timeout(10 * 60 * 1000)
        except KeyboardInterrupt:
            pass
        finally:
            if not args.cdp:
                browser.close()


if __name__ == "__main__":
    main()
