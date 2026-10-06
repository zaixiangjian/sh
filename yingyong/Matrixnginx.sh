server {
    listen 80;
    listen [::]:80;
    server_name m.example.xyz;

    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name m.example.xyz;

    ssl_stapling on;
    ssl_stapling_verify on;

    resolver 1.1.1.1 8.8.8.8 223.5.5.5 valid=300s;
    resolver_timeout 5s;

    ssl_certificate /etc/nginx/certs/m.example.xyz_cert.pem;
    ssl_certificate_key /etc/nginx/certs/m.example.xyz_key.pem;

    client_max_body_size 1000m;

    # Matrix API：转发到 Synapse，保留原始请求路径
    location /_matrix {
        proxy_pass http://192.168.100.225:8003;

        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_read_timeout 600s;
    }

    # Synapse 客户端接口
    location /_synapse/client {
        proxy_pass http://192.168.100.225:8003;

        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;

        proxy_read_timeout 600s;
    }

    # Element 网页客户端
    location / {
        proxy_pass http://192.168.100.225:8004;

        proxy_http_version 1.1;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $remote_addr;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
