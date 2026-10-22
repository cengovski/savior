B=http://127.0.0.1:3999; J=/tmp/savior-admin-jar; rm -f $J
t(){ printf '%-48s %s\n' "$1" "$2"; }
t "GET / logged out" "$(curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}' $B/)"
t "GET /login" "$(curl -s -o /dev/null -w '%{http_code}' $B/login)"
t "POST /login wrong pw" "$(curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}' -d password=wrong $B/login)"
t "POST /login right pw" "$(curl -s -c $J -o /dev/null -w '%{http_code} -> %{redirect_url}' -d password=$P $B/login)"
t "cookie flags" "$(grep -c savior_admin $J) cookie(s) stored; $(curl -s -D - -o /dev/null -d password=$P $B/api/login | grep -i set-cookie | sed 's/=[^;]*;/=<redacted>;/')"
t "GET / with cookie" "$(curl -s -b $J -w ' %{http_code}' $B/ | grep -o 'SAVIOR Admin Panel\| [0-9]*$' | tr '\n' ' ')"
t "GET / tampered cookie" "$(curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}' -H 'Cookie: __Host-savior_admin=eyJ4IjoxfQ.abc' $B/)"
t "GET /protected/admin.html" "$(curl -s -o /dev/null -w '%{http_code}' $B/protected/admin.html)"
t "GET /api/panel no cookie" "$(curl -s -o /dev/null -w '%{http_code}' $B/api/panel)"
t "GET /robots.txt" "$(curl -s -o /dev/null -w '%{http_code}' $B/robots.txt)"
t "POST /logout" "$(curl -s -D - -o /dev/null -X POST $B/logout | grep -i 'set-cookie\|^HTTP' | tr -d '\r' | tr '\n' ' ')"
for i in 1 2 3 4 5 6; do c=$(curl -s -o /dev/null -w '%{http_code}' -d password=x $B/login); done; t "rate limit after many tries" "$c"
