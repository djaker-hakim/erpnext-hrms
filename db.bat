@REM this is a docker command to simulate a stand alone db server

docker run -d --name db -e MYSQL_ROOT_PASSWORD=admin -e MARIADB_ROOT_PASSWORD=admin -p 3306:3306 -v db-data:/var/lib/mysql mariadb:10.6 --character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci --skip-character-set-client-handshake --skip-innodb-read-only-compressed