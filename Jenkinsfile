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

          // echo "== YAML lint (optional) =="
          // if command -v yamllint >/dev/null 2>&1; then
          //   yamllint -d "{extends: relaxed, rules: {line-length: disable}}" .
          // else
          //   echo "⚠️ yamllint not installed — skip"
          // fi
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
          set -e
          echo "== Run container for test on 8088 =="
          "${DOCKER_BIN}" run -d --rm -p 8088:80 --name webtest ${DOCKER_IMAGE}:${SHORT_SHA}
          for i in $(seq 1 20); do
            code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8088 || true)
            [ "$code" = "200" ] && break
            sleep 1
          done
          "${DOCKER_BIN}" stop webtest || true
          [ "$code" = "200" ] || { echo "❌ Test failed: HTTP $code"; exit 1; }
          echo "✅ Test passed (HTTP 200)"
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
        dir('infra-src') {
          git url: "${INFRA_REPO_URL}", branch: "${INFRA_BRANCH}"
        }

        // Гарантируем наличие каталога и пишем inventory
        sh '''
          set -e
          echo "== workspace =="
          pwd
          echo "== tree infra-src =="
          ls -la infra-src || true
          ls -la infra-src/ansible || true
          mkdir -p infra-src/ansible

          cat > infra-src/ansible/inventory.ini <<'EOF'
          [web]
          assugan.click
          EOF
          echo "== inventory.ini =="
          cat infra-src/ansible/inventory.ini
        '''

        withCredentials([
          sshUserPrivateKey(
            credentialsId: 'ec2-ssh-private',   // ДОЛЖЕН существовать в Jenkins
            keyFileVariable: 'SSH_KEY_FILE',
            usernameVariable: 'SSH_USER'
          )
        ]) {
          dir('infra-src/ansible') {
            sh '''
              set -euxo pipefail

              # Диагностика окружения
              echo "== whoami =="; whoami || true
              echo "== PATH =="; echo "$PATH"
              which ansible || true
              which ansible-playbook || true
              ansible --version

              # Проверим, что креды подтянулись
              echo "SSH_USER=${SSH_USER}"
              test -n "$SSH_USER"             # если пусто — нет username в кредах
              test -s "$SSH_KEY_FILE"         # если нет файла — неверный credsId/тип

              export ANSIBLE_HOST_KEY_CHECKING=False

              ansible-playbook -i inventory.ini site.yml \
                -u "$SSH_USER" --private-key "$SSH_KEY_FILE" \
                --extra-vars "app_domain=''' + "${APP_DOMAIN}" + ''' image_repo=''' + "${DOCKER_IMAGE}" + ''' image_tag=latest"
            '''
          }
        }
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
