"""A controlled browser-like sign-in using only the training Services."""
from html.parser import HTMLParser
from http.cookiejar import CookieJar
import json
import sys
from urllib.error import HTTPError
from urllib.parse import urlencode, urljoin, urlsplit
from urllib.request import build_opener, HTTPRedirectHandler, HTTPCookieProcessor, Request

PORTAL = "http://login-portal:4180"
PROTECTED = PORTAL + "/api/status"


class Redirects(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urlsplit(newurl).hostname not in {"login-portal", "login-idp"}:
            raise ValueError("Unexpected redirect outside the training Services")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, *args):
        return None


class LoginPage(HTMLParser):
    def __init__(self):
        super().__init__()
        self.action = None
        self.provider = None

    def handle_starttag(self, tag, attrs):
        fields = dict(attrs)
        if tag == "form" and fields.get("method", "").lower() == "post":
            self.action = fields.get("action", "")
        if tag == "a" and "/auth/local" in fields.get("href", ""):
            self.provider = fields["href"]


def anonymous_check():
    with_error = build_opener(NoRedirect())
    try:
        with_error.open(PROTECTED, timeout=4).close()
    except HTTPError as error:
        if error.code in (302, 303, 401, 403):
            return
        raise
    raise ValueError("Expected a login challenge for an unauthenticated request")


def get_form(opener, url):
    with opener.open(url, timeout=5) as response:
        page = LoginPage()
        page.feed(response.read().decode())
        return page, response.geturl()


def sign_in():
    opener = build_opener(HTTPCookieProcessor(CookieJar()), Redirects())
    page, url = get_form(opener, PORTAL + "/oauth2/start?rd=%2Fapi%2Fstatus")
    if page.action is None and page.provider:
        page, url = get_form(opener, urljoin(url, page.provider))
    if page.action is None:
        raise ValueError("Dex did not return its password form")
    form = urljoin(url, page.action)
    if urlsplit(form).hostname != "login-idp":
        raise ValueError("Unexpected login form destination")
    data = {"login": "operator@example.test", "password": "password"}
    with opener.open(Request(form, data=urlencode(data).encode()), timeout=5) as response:
        result = json.load(response)
        if response.geturl() != PROTECTED or result != {"status": "protected report available"}:
            raise ValueError("The signed-in request did not reach the protected report")


def main():
    mode = sys.argv[1]
    anonymous_check()
    try:
        sign_in()
    except HTTPError as error:
        body = error.read().decode(errors="replace").lower()
        if urlsplit(error.geturl()).hostname == "login-idp" and error.code == 400 and "redirect" in body:
            print("The identity provider rejected the portal redirect.")
            if mode == "broken":
                return
            sys.exit(1)
        raise
    if mode == "broken":
        sys.exit("The sign-in flow unexpectedly worked")
    print("PASS: The demo user reached the report. A fresh anonymous request was denied.")


if __name__ == "__main__":
    main()
