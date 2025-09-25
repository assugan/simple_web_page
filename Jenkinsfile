pipeline {
  agent any

  environment {
    // чтобы локальный Jenkins (macOS) видел docker/ansible
    PATH = "/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:${PATH}"

    // Docker Hub образ
    DOCKER_IMAGE = "docker.io/assugan/web-app"

    // домен твоего EC2
    APP_DOMAIN   = "assugan.click"

    // ansible из отдельного репо инфраструктуры
    INFRA_REPO_URL = "https://github.com/assugan/infrastructure.git"
    INFRA_BRANCH   = "main"

    // уведомления
    TELEGRAM_BOT_TOKEN = credentials('telegram-bot-token')
    TELEGRAM_CHAT_ID   = credentials('telegram-chat-id')
  }

  options { timestamps() }

  stages {
    stage('Checkout + Meta') {
      steps {
        checkout scm
        script {
          env.SHORT_SHA   = sh(script: "git rev-parse --short=12 HEAD", returnStdout: true).trim()
          env.BRANCH_SAFE = (env.CHANGE_BRANCH ?: env.BRANCH_NAME).replaceAll('/','-').toLowerCase()
        }
      }
    }

    stage('Detect Docker') {
      steps {
        sh '''
          set -e
          echo "== whoami =="; whoami || true
          echo "== PATH =="; echo "$PATH"

          CANDIDATES="
            /opt/homebrew/bin/docker
            /usr/local/bin/docker
            /Applications/Docker.app/Contents/Resources/bin/docker
          "
          for p in $CANDIDATES; do
            if [ -x "$p" ]; then
              echo "Found docker at: $p"
              echo "DOCKER_BIN=$p" > .docker_path
              break
            fi
          done
          if [ ! -f .docker_path ]; then
            echo "❌ Docker binary not found"
            exit 1
          fi
          . .docker_path
          "$DOCKER_BIN" version
        '''
        script {
          env.DOCKER_BIN = sh(script: 'source .docker_path && echo "$DOCKER_BIN"', returnStdout: true).trim()
        }
      }
    }

    stage('Lint') {
      steps {
        sh '''
          echo "== Dockerfile lint =="
          if command -v hadolint >/dev/null 2>&1; then
            hadolint Dockerfile || exit 1
          else
            echo "⚠️ hadolint not installed — skip"
          fi

          # echo "== YAML lint (optional) =="
          # if command -v yamllint >/dev/null 2>&1; then
          #   yamllint -d "{extends: relaxed, rules: {line-length: disable}}" .
          # else
          #   echo "⚠️ yamllint not installed — skip"
          # fi
        '''
      }
    }

    stage('Build (Docker)') {
      steps {
        sh '''
          set -e
          "${DOCKER_BIN}" build -t ${DOCKER_IMAGE}:${SHORT_SHA} .
          if [ "${BRANCH_NAME}" = "main" ]; then
            "${DOCKER_BIN}" tag ${DOCKER_IMAGE}:${SHORT_SHA} ${DOCKER_IMAGE}:latest
          else
            SAFE_TAG=$(echo "${BRANCH_SAFE}" | sed 's/[^a-zA-Z0-9_.-]/-/g')
            "${DOCKER_BIN}" tag ${DOCKER_IMAGE}:${SHORT_SHA} ${DOCKER_IMAGE}:${SAFE_TAG}
          fi
        '''
      }
    }

    stage('Test (container smoke)') {
      steps {
        sh '''
          set -euo pipefail
          echo "== Run container smoke test =="

          DOCKER_BIN="${DOCKER_BIN:-/usr/local/bin/docker}"

          NAME="webtest-${BUILD_TAG}"
          IMAGE="${DOCKER_IMAGE}:${SHORT_SHA}"

          # Удалим только наш контейнер, если вдруг остался
          $DOCKER_BIN rm -f "$NAME" >/dev/null 2>&1 || true

          # Запускаем с рандомным хост-портом
          CID=$($DOCKER_BIN run -d --rm \
            --name "$NAME" \
            -p 0:80 \
            "$IMAGE")
          echo "$CID"

          # Узнаём выданный порт (берём первый ряд, там IPv4)
          PORT=""
          for i in $(seq 1 10); do
            LINE=$($DOCKER_BIN port "$NAME" 80/tcp || true)
            PORT=$(printf "%s" "$LINE" | head -n1 | cut -d: -f2)
            [ -n "$PORT" ] && break
            sleep 1
          done
          [ -n "$PORT" ] || { echo "❌ Can't determine mapped port for $NAME"; $DOCKER_BIN rm -f "$NAME" || true; exit 1; }

          echo "Container: $NAME -> http://localhost:$PORT"

          # Уборка даже при ошибке
          trap '$DOCKER_BIN rm -f "$NAME" >/dev/null 2>&1 || true' EXIT

          # Ждём до 20 сек HTTP 200
          code=""
          for i in $(seq 1 20); do
            code=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:$PORT" || true)
            [ "$code" = "200" ] && break
            sleep 1
          done

          [ "$code" = "200" ] || { echo "❌ Test failed: HTTP $code (port $PORT)"; exit 1; }
          echo "✅ Test passed (HTTP 200) on port $PORT"
        '''
      }
    }

    // main: multi-arch push через buildx
    stage('Docker Buildx & Push (main only)') {
      when { allOf { expression { env.BRANCH_NAME == 'main' }; not { changeRequest() } } }
      steps {
        withCredentials([usernamePassword(credentialsId: 'dockerhub-creds', usernameVariable: 'DH_USER', passwordVariable: 'DH_PASS')]) {
          sh '''
            set -euo pipefail
            echo "$DH_PASS" | "${DOCKER_BIN}" login -u "$DH_USER" --password-stdin

            "${DOCKER_BIN}" buildx create --name web_builder --use || true
            "${DOCKER_BIN}" buildx inspect --bootstrap

            "${DOCKER_BIN}" buildx build \
              --platform linux/amd64,linux/arm64 \
              -t "${DOCKER_IMAGE}:${BRANCH_SAFE}-${SHORT_SHA}" \
              -t "${DOCKER_IMAGE}:${BUILD_NUMBER}" \
              -t "${DOCKER_IMAGE}:latest" \
              -f Dockerfile \
              --push \
              .

            "${DOCKER_BIN}" logout || true
          '''
        }
      }
    }

    // feature-ветки: обычный push тегов SHA и branch
    stage('Push (non-main branches)') {
      when { allOf { expression { env.BRANCH_NAME != 'main' }; not { changeRequest() } } }
      steps {
        withCredentials([usernamePassword(credentialsId: 'dockerhub-creds', usernameVariable: 'DH_USER', passwordVariable: 'DH_PASS')]) {
          sh '''
            set -e
            echo "$DH_PASS" | "${DOCKER_BIN}" login -u "$DH_USER" --password-stdin
            SAFE_TAG=$(echo "${BRANCH_SAFE}" | sed 's/[^a-zA-Z0-9_.-]/-/g')
            "${DOCKER_BIN}" push ${DOCKER_IMAGE}:${SHORT_SHA}
            "${DOCKER_BIN}" push ${DOCKER_IMAGE}:${SAFE_TAG}
            "${DOCKER_BIN}" logout || true
          '''
        }
      }
    }

    // деплой только для main
    stage('Deploy (Ansible, main only)') {
      when { allOf { expression { env.BRANCH_NAME == 'main' }; not { changeRequest() } } }
      steps {
        echo "== MARK:DEPLOY:START =="

        // 1) тянем актуальную инфру (репо с ansible)
        dir('infra-src') {
          git url: "${INFRA_REPO_URL}", branch: "${INFRA_BRANCH}"
        }

        // 2) inventory рядом с playbook
        sh '''
          set -euo pipefail
          echo "== MARK:DEPLOY:PREP =="
          ls -la infra-src || true
          ls -la infra-src/ansible || true
          mkdir -p infra-src/ansible
          printf "[web]\\n%s\\n" "${APP_DOMAIN:-assugan.click}" > infra-src/ansible/inventory.ini
          echo "== inventory.ini =="; cat infra-src/ansible/inventory.ini
          echo "== MARK:AFTER-CAT =="
        '''

        echo "== MARK:BEFORE-CREDS =="

        // 3) SSH-креды и Ansible — ОБЯЗАТЕЛЬНО внутри steps{}
        withCredentials([sshUserPrivateKey(
          credentialsId: 'ec2-ssh-key',        // Jenkins Credentials: SSH Username with private key (username=ubuntu)
          keyFileVariable: 'SSH_KEY_FILE',
          usernameVariable: 'SSH_USER'
        ),
        string(credentialsId: 'grafana-admin-password', variable: 'GRAFANA_ADMIN_PASSWORD'),     // ⬅︎ NEW
        string(credentialsId: 'telegram-bot-token',     variable: 'TELEGRAM_BOT_TOKEN'),          // ⬅︎ NEW
        string(credentialsId: 'telegram-chat-id',       variable: 'TELEGRAM_CHAT_ID') 
        ]) {
          dir('infra-src/ansible') {
            sh '''
              set -euxo pipefail
              echo "== MARK:DEPLOY:RUN =="

              echo "== Ansible =="
              which ansible || true
              ansible --version

              echo "== SSH creds =="
              echo "SSH_USER=${SSH_USER}"
              test -n "$SSH_USER"
              test -s "$SSH_KEY_FILE"
              ls -l "$SSH_KEY_FILE" || true

              export ANSIBLE_HOST_KEY_CHECKING=False

              echo "== Ping host =="
              ansible -i inventory.ini web -u "$SSH_USER" --private-key "$SSH_KEY_FILE" -m ping -vv

              echo "== Playbook =="
              ansible-playbook -i inventory.ini site.yml \
                -u "$SSH_USER" --private-key "$SSH_KEY_FILE" \
                --extra-vars "app_domain=${APP_DOMAIN} image_repo=${DOCKER_IMAGE} image_tag=latest grafana_admin_password=${GRAFANA_ADMIN_PASSWORD} telegram_bot_token=${TELEGRAM_BOT_TOKEN} telegram_chat_id=${TELEGRAM_CHAT_ID}" -vv

              echo "== MARK:DEPLOY:DONE =="
            '''
          }
        }

        echo "== MARK:DEPLOY:END =="
      }
    }
  }

  post {
    success { script { notifyTG("✅ Pipeline OK: ${env.JOB_NAME} #${env.BUILD_NUMBER}") } }
    failure { script { notifyTG("🔥 Pipeline FAILED: ${env.JOB_NAME} #${env.BUILD_NUMBER}") } }
  }
}

def notifyTG(String msg) {
  withEnv(["MSG=${msg}"]) {
    sh '''curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d chat_id="${TELEGRAM_CHAT_ID}" --data-urlencode "text=${MSG}"'''
  }
}
