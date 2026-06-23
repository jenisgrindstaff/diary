# Nginx + Authelia Deployment

This setup keeps the browser Web UI behind Authelia while leaving the iOS API on Diary's bearer-token authentication.

```text
https://diary.example.com/              -> nginx + Authelia -> Diary Web UI
https://diary.example.com/assets/...    -> nginx + Authelia -> Diary Web media
https://diary.example.com/api/v1/...    -> Diary bearer token auth for iOS
https://diary.example.com/share/...     -> public signed share links
```

## Diary Environment

Set these on the Diary container when it is behind nginx/Authelia:

```sh
DIARY_API_TOKEN=replace-with-a-long-random-setup-token
DIARY_WEB_AUTH_HEADER=Remote-User
DIARY_WEB_AUTH_PROXY_SECRET=replace-with-a-long-random-proxy-secret
```

`DIARY_WEB_AUTH_HEADER` tells Diary which header nginx sets after Authelia succeeds.
`DIARY_WEB_AUTH_PROXY_SECRET` makes the Go app reject Web UI requests unless nginx also adds a shared secret header.

Keep the Diary container reachable only from the Docker/internal network. Do not publish the Diary port directly to the internet.

## Nginx Shape

Adapt this to your nginx layout. The important parts are:

- `/api/` bypasses Authelia so iOS can use `Authorization: Bearer ...`.
- Browser routes use `auth_request`.
- Nginx overwrites `Remote-User` and `X-Diary-Proxy-Secret` before proxying.
- `/assets/` is protected because diary media is private.

```nginx
server {
    server_name diary.example.com;

    client_max_body_size 1024m;

    location = /authelia {
        internal;
        proxy_pass http://authelia:9091/api/authz/auth-request;
        proxy_pass_request_body off;
        proxy_set_header Content-Length "";
        proxy_set_header X-Original-URL $scheme://$http_host$request_uri;
        proxy_set_header X-Original-Method $request_method;
        proxy_set_header X-Forwarded-Method $request_method;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-Host $http_host;
        proxy_set_header X-Forwarded-Uri $request_uri;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Real-IP $remote_addr;
    }

    location /api/ {
        proxy_pass http://diary:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Authorization $http_authorization;
        proxy_set_header Remote-User "";
        proxy_set_header X-Diary-Proxy-Secret "";
    }

    location /healthz {
        proxy_pass http://diary:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /share/ {
        proxy_pass http://diary:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Remote-User "";
        proxy_set_header X-Diary-Proxy-Secret "";
    }

    location / {
        auth_request /authelia;
        auth_request_set $user $upstream_http_remote_user;
        auth_request_set $email $upstream_http_remote_email;
        error_page 401 =302 https://auth.example.com/?rd=$scheme://$http_host$request_uri;

        proxy_pass http://diary:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header Remote-User $user;
        proxy_set_header Remote-Email $email;
        proxy_set_header X-Diary-Proxy-Secret "replace-with-the-same-long-random-proxy-secret";
    }
}
```

## iOS Setup

In the iOS app settings:

```text
Server URL: https://diary.example.com
Setup token: DIARY_API_TOKEN value
```

After device registration, iOS stores its own device token and continues using `Authorization: Bearer ...`.

## Authelia Policy

Require two-factor authentication for the Diary Web UI domain:

```yaml
access_control:
  default_policy: deny
  rules:
    - domain: diary.example.com
      policy: two_factor
```

## Share Links

`/share/{token}` remains public because the link itself is signed. Private media under `/assets/` remains behind Authelia, so public share pages may not display media unless the viewer is authenticated.
