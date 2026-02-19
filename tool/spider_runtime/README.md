# Spider Runtime Bridge

This folder contains local runner scripts used by Flutter process executors.

Protocol: line-delimited JSON-RPC style messages over stdin/stdout.

Request:
{"id":"<uuid>","method":"playerContent","params":{...}}

Response:
{"id":"<uuid>","result":{...}}
{"id":"<uuid>","error":{"code":"RUNTIME_ERROR","message":"..."}}

Required methods:
- init
- homeContent
- categoryContent
- detailContent
- searchContent
- playerContent
- proxyLocal
- destroy

Note: the default runner implemented here is a local scaffold so the app can run
end-to-end in macOS development. Real spider engines can replace this runner later.
