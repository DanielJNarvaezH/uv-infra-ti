FROM ubuntu:22.04

RUN apt update && apt install -y chrony && apt clean

COPY chrony.conf /etc/chrony/chrony.conf

EXPOSE 123/udp

CMD ["chronyd", "-d", "-f", "/etc/chrony/chrony.conf"]
