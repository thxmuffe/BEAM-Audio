# WebApp

Repository split (2026-11-03): see [current build paths](../../BUILDING.md).
Product sources now live in the sibling OpenSound checkout; shared runtime,
tooling and documentation live here. Older monorepo paths below are historical.

The browser app belongs here, alongside macOS, iOS and Windows. The independent
[Reception Desk service](../../Services/ReceptionDesk/README.md) belongs under
`src/Services/ReceptionDesk` and can serve any kind of client or future transport.

The full browser app is deferred. This preserves the existing legacy directory/QR frontend;
it uses the explicitly separate legacy directory launcher below, not the relay endpoint. It is not yet a browser node:
it has no Erlang runtime, swarm chat, graph or internet invitation transport.
Harmonizing it with the native apps remains future work.

## Local development

Run these in separate terminals from the repository root:

```sh
bash src/Services/ReceptionDesk/run-legacy.sh
bash src/Apps/WebApp/run.sh
```

Open `http://127.0.0.1:8766`. The WebApp's local Python development host serves
static assets and forwards `/api/` requests to the independently running
Reception Desk at `http://127.0.0.1:8765`. It does not start or own that service.

Set `PARVI_RECEPTION_DESK_URL` to choose another service endpoint and
`PARVI_WEBAPP_PORT` to change the frontend's local port. The development server
binds only to loopback. A localhost QR opens this page on the scanning device,
not this computer; it cannot connect an iPhone to the Mac.

## Static build

```sh
bash src/Apps/WebApp/build.sh
```

Output: `builds/WebApp/`. It can be hosted independently with an `/api/`
reverse-proxy rule to the Reception Desk. The Python host is a local development
helper, not a production deployment server. Separating the sources does not
require separate domains or hosting providers.

## QR dependency

`public/qrcode.js` vendors `qrcode-generator` 2.0.4 by Kazuhiko Arase under MIT.
See [QRCODE-LICENSE](../../../../OpenSound/src/Apps/WebApp/QRCODE-LICENSE) and
[upstream](https://github.com/kazuhikoarase/qrcode-generator).
Its npm archive was verified with:

```text
sha512-mZSiP6RnbHl4xL2Ap5HfkjLnmxfKcPWpWe/c+5XxCuetEenqmNFf1FH/ftXPCtFG5/TDobjsjz6sSNL0Sr8Z9g==
```

QR generation stays local to the browser.
