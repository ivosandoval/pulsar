#!/bin/bash

# Web entrypoint

chmod 600 /etc/ssh/sandbox_key
chown nginx:nogroup /etc/ssh/sandbox_key


# Generate secret keys

export D_SECRET_KEY=$(openssl rand -base64 128)

# Wait for database

until netcat -z db 3306 ; do
  >&1
  echo "waiting for mysql"
  sleep 1
done

# Wait for queue
until netcat -z queue 5672 ; do
  >&1
  echo "waiting for rabbitmq"
  sleep 1
done


# Generate celery certificate
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 -subj \
    "/C=PL/ST=Masovian/L=Warsaw/O=PulsarApp/OU=DevOps/CN=celery.local>"\
    -keyout /etc/ssl/server.key -out /etc/ssl/server.crt

# Generate pulsar cerificate
openssl req -new -newkey rsa:4096 -days 3650 -nodes -x509 -subj \
    "/C=PL/ST=Masovian/L=Warsaw/O=PulsarApp/OU=Pulsar/CN=pulsar.local>"\
    -keyout /etc/ssl/pulsar.key -out /etc/ssl/pulsar.crt

# Start sandbox ssh tunnel
ssh -o StrictHostKeyChecking=no -o LogLevel=quiet -f -N -D 127.0.0.1:8881 sandbox -i /etc/ssh/sandbox_key 2>/dev/null
# Set sandbox proxy
#export ALL_PROXY=socks5://localhost:8881/

# Collect static files
echo "Collect static files"
python manage.py makemigrations

# Apply database migrations
echo "Apply database migrations"
python manage.py migrate

# Add django admin user
echo "from django.contrib.auth import get_user_model;\
  User = get_user_model();\
  User.objects.create_superuser(\
  '${DJANGO_ADMIN_USER}', 'root@localhost', '${DJANGO_ADMIN_PASS}')" | python manage.py shell

# Set up celery workers
screen -dmS worker celery -A pulsar worker -l info \
 --broker="amqp://${RABBITMQ_DEFAULT_USER}:${RABBITMQ_DEFAULT_PASS}@queue:5671//" --statedb=/portal/celery.state \
 -f /portal/logs/celery.log --autoscale=8,2 --uid nginx --gid nogroup
screen -dmS beat celery -A pulsar worker --beat -l info -f /portal/logs/celery.log \
 --broker="amqp://${RABBITMQ_DEFAULT_USER}:${RABBITMQ_DEFAULT_PASS}@queue:5671//" \
 --scheduler='django_celery_beat.schedulers:DatabaseScheduler' --autoscale=8,2 --uid nginx --gid nogroup


# Apply database migrations
python manage.py makemigrations
python manage.py migrate

# Get static files
python manage.py collectstatic --noinput

# Setup nginx
chown nginx /etc/ssl/server.key
cp /portal/conf/site.conf /etc/nginx/sites-enabled/pulsar
service nginx start
cd /portal/

# Start application server
echo -e "\n\033[32m[!] Starting pulsar on https://localhost:8443/\n"
echo -e "    It can take a while to boot.\n\033[0m"
/portal/conf/gunicorn.sh
