# Simple Web Page

Небольшое веб-приложение (статический сайт), собираемое в Docker-образ и публикуемое через Jenkins. Используется в качестве демо-приложения для пайплайна CI/CD и мониторинга.

## Что внутри
- `Dockerfile` — сборка образа Nginx со статикой.
- `Jenkinsfile` — многостадийный pipeline:
  - **Build**: сборка и пуш Docker-образа `assugan/web-app:<short_sha>` и `assugan/web-app:latest`.
  - **Test (container smoke)**: запуск контейнера на **рандомном хост-порту** (`-p 0:80`) и проверка HTTP 200.
  - **Deploy (main)**: триггерит Ansible из репо `infrastructure` (деплой мониторинга и настройка сервисов на EC2).

## Быстрый старт локально
```
# Сборка
docker build -t assugan/web-app:local .

# Запуск (Nginx внутри слушает 80)
docker run --rm -p 8081:80 --name webtest assugan/web-app:local

# Открыть в браузере:
http://localhost:8081  # порт 8081 по причинине что 8080 будет занят Jenkins
```

## CI/CD
  - Пайплайн настроен в Jenkins:
	- Сборка образа и пуш в DockerHub.
	- Запуск smoke-теста контейнера.
	- Деплой на EC2 (выполняется из отдельного репозитория [infrastructure](https://github.com/assugan/infrastructure)).

## Дополнительно
## Jenkins: Установка и настройка (macOS)

### 1. Установка Jenkins на macOS
```
# Установка через Homebrew
brew install jenkins-lts

# Запуск сервиса
brew services start jenkins-lts

# Проверка статуса
brew services list

# Jenkins будет доступен по адресу:
# http://localhost:8080
```
### 2. Настройка Multibranch Pipeline
1. Перейдите в браузере по адресу: http://localhost:8080
2. Установите рекомендованные плагины (или необходимые вручную).
3. Настройка Multibranch Pipeline:
	- Перейдите: Dashboard → New Item → Multibranch Pipeline
	- Введите имя проекта (например: simple-web-page)
	- Выберите “Multibranch Pipeline” → OK
	- В настройках пайплайна:
	   - Branch Sources → GitHub
	   - Укажите URL репозитория приложения
	   - Настройте GitHub credentials (токен или логин/пароль)
	- Включите автоматическое сканирование веток:
	   - Scan Multibranch Pipeline Triggers → Periodically if not otherwise run
	- Jenkins автоматически найдёт Jenkinsfile в репозитории и создаст джобы для всех веток.

**Теперь при каждом пуше в ветки репозитория Jenkins будет автоматически запускать пайплайн на основе Jenkinsfile**
