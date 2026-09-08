# Troubleshooting: установка Kubernetes на ALT Linux

В этом документе собраны типичные проблемы, возникающие при автоматической установке Kubernetes с помощью `install-k8s.sh`, и способы их решения.

## 1. Flannel не запускается: отсутствует `/run/flannel/subnet.env`

**Симптом:** поды остаются в состоянии `ContainerCreating`, события показывают ошибку:
`loadFlannelSubnetEnv failed: open /run/flannel/subnet.env: no such file or directory`.

**Причина:** Flannel pod не смог стартовать из-за проблем с образами или доступом к API-серверу.

**Решение:**
- Проверить поды Flannel: `kubectl get pods -n kube-flannel`.
- Посмотреть логи: `kubectl logs -n kube-flannel <имя_пода>`.
- Если образы недоступны, импортировать их вручную через `ctr`.
- Создать файл вручную и перезапустить kubelet:
  ```bash
  mkdir -p /run/flannel
  cat > /run/flannel/subnet.env <<EOF
  FLANNEL_NETWORK=10.244.0.0/16
  FLANNEL_SUBNET=10.244.0.1/24
  FLANNEL_MTU=1450
  FLANNEL_IPMASQ=true
  EOF
  systemctl restart kubelet
  kubectl delete pod -n kube-flannel --all


2. Ошибки TLS при скачивании манифестов и образов

Симптом: tls: failed to verify certificate, 403 Forbidden при обращении к raw.githubusercontent.com или ghcr.io.

Причина: корпоративный файрвол перехватывает HTTPS-трафик и подменяет сертификаты.

Решение:

    Использовать зеркала: https://cdn.jsdelivr.net/gh/... вместо raw.githubusercontent.com.

    Отключать проверку TLS: curl -k, wget --no-check-certificate.

    Заменять внешние реестры на доверенные (например, registry.altlinux.org).

3. Проброс портов через -p не работает на ALT Linux

Симптом: приложение внутри контейнера не отвечает с хоста при использовании docker run -p 8080:5000.

Причина: конфликт docker-proxy с loopback-интерфейсом.

Решение: использовать --network host для контейнеров, либо настраивать firewall и маршруты вручную.
4. coredns в состоянии Pending или Unknown

Симптом: kubectl get pods -n kube-system показывает coredns не в Running.

Причина: отсутствует или не работает сетевой плагин (CNI).

Решение: убедиться, что Flannel (или другой CNI) установлен и его поды запущены. См. пункт 1.
5. Kubelet не может использовать containerd (cgroup driver)

Симптом: kubelet в статусе Error, в логах сообщение о несовпадении cgroup driver (systemd vs cgroupfs).

Решение: в /etc/containerd/config.toml установить SystemdCgroup = true, перезапустить containerd и kubelet:
bash

systemctl restart containerd
systemctl restart kubelet

6. kubeadm init завершается с ошибкой занятого порта 6443

Симптом: Port 6443 is in use.

Решение: выполнить сброс и повторить инициализацию:
bash

kubeadm reset -f
kubeadm init ...

7. kubectl не подключается к кластеру

Симптом: The connection to the server localhost:8080 was refused.

Решение: скопировать конфигурацию администратора:
bash

mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

8. Ошибка Permission denied при импорте образов через ctr

Симптом: ctr: connect: permission denied при обращении к сокету containerd.

Решение: выполнять команды от root или добавить пользователя в группу docker:
bash

sudo usermod -aG docker $USER
newgrp docker

9. Недоступность образов Kubernetes из-за сетевых ограничений

Симптом: ErrImagePull / ImagePullBackOff при попытке запустить поды kube-system.

Решение: использовать зеркала (например, registry.aliyuncs.com/google_containers для компонентов control-plane), а также локальный registry для остальных образов.
10. Поды не запускаются после перезагрузки

Симптом: после перезагрузки ноды кластер не работает, поды в Unknown/ContainerCreating.

Решение: проверить, что containerd, kubelet и docker запущены:
bash

systemctl status containerd kubelet docker

При необходимости включить автозапуск:
bash

systemctl enable --now containerd kubelet docker

text


## Обновляем `k8s-install/README.md`

Теперь нужно добавить ссылку на файл траблшутинга в README раздела k8s-install. Открой файл:

```bash
nano k8s-install/README.md


Подробные инструкции по устранению типичных ошибок смотрите в [TROUBLESHOOTING.md](./TROUBLESHOOTING.md).
