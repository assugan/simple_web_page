pipeline {
  agent any

  tools { /* maven не нужен */ }

  environment {
    // Чтобы Jenkins видел docker/ansible/… на macOS (Homebrew + Docker Desktop)
    PATH = "/usr/local/bin:/opt/homebrew/bin:/Applications/Docker.app/Contents/Resources/bin:${PATH}"

    // Образ в Docker Hub
    DOCKER_IMAGE = "assugan/web-app"

    // Домен твоего EC2 (Terraform уже настроил)
    APP_DOMAIN   = "assugan.click"

    // Откуда берём Ansible роли (как мы их готовили)
    INFRA_REPO_URL = "https://github.com/assugan/infrastructure.git"
    INFRA_BRANCH   = "draft-infra"

    // Уведомления
    TELEGRAM_BOT_TOKEN = credentials('telegram-bot-token')
    TELEGRAM_CHAT_ID   = credentials('telegram-chat-id')
  }

  options { timestamps() }

  stages {
    stage('Checkout + Meta') {
      steps {
        checkout scm
        script {
          env.SHORT_SHA   = sh(script: "git rev-parse --short HEAD", returnStdout: true).trim()
          env.BRANCH_SAFE = (env.CHANGE_BRANCH ?: env.BRANCH_NAME).replaceAll('/','-').toLowerCase()
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
            echo "⚠️ hadolint not installed — пропускаю"
          fi

          echo "== YAML lint (опционально) =="
          if command -v yamllint >/dev/null 2>&1; then
            yamllint -d "{extends: relaxed, rules: {line-length: disable}}" .
          else
            echo "⚠️ yamllint not installed — пропускаю"
          fi
        '''
      }
    }

    stage('Build (Docker)') {
      steps {
        sh '''
          set -e
          docker build -t ${DOCKER_IMAGE}:${SHORT_SHA} .
          # Дополнительный тег: для main — latest, для остальных — имя ветки
          if [ "${BRANCH_NAME}" = "main" ]; then
            docker tag ${DOCKER_IMAGE}:${SHORT_SHA} ${DOCKER_IMAGE}:latest
          else
            SAFE_TAG=$(echo "${BRANCH_SAFE}" | sed 's/[^a-zA-Z0-9_.-]/-/g')
            docker tag ${DOCKER_IMAGE}:${SHORT_SHA} ${DOCKER_IMAGE}:${SAFE_TAG}
          fi
        '''
      }
    }

    stage('Test (container smoke)') {
      steps {
        sh '''
          set -e
          echo "== Run container for test on 8088 =="
          docker run -d --rm -p 8088:80 --name webtest ${DOCKER_IMAGE}:${SHORT_SHA}
          # подождём старт nginx в контейнере
          for i in $(seq 1 20); do
            code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8088 || true)
            [ "$code" = "200" ] && break
            sleep 1
          done
          docker stop webtest || true
          if [ "$code" != "200" ]; then
            echo "❌ Test failed: HTTP $code"
            exit 1
          fi
          echo "✅ Test passed (HTTP 200)"
        '''
      }
    }

    stage('Docker Buildx & Push (main only)') {
      when {
        allOf {
          expression { env.BRANCH_NAME == 'main' } // только ветка main
          not { changeRequest() }                  // и это не PR
        }
      }
      steps {
        withCredentials([usernamePassword(credentialsId: 'dockerhub-creds', usernameVariable: 'DH_USER', passwordVariable: 'DH_PASS')]) {
          sh '''
            set -euo pipefail
            echo "$DH_PASS" | docker login -u "$DH_USER" --password-stdin

            # buildx для multi-arch (Mac arm64 -> amd64 в облаке)
            docker buildx create --name web_builder --use || true
            docker buildx inspect --bootstrap

            docker buildx build \
              --platform linux/amd64,linux/arm64 \
              -t "${DOCKER_IMAGE}:${BRANCH_SAFE}-${SHORT_SHA}" \
              -t "${DOCKER_IMAGE}:${BUILD_NUMBER}" \
              -t "${DOCKER_IMAGE}:latest" \
              -f Dockerfile \
              --push \
              .

            docker logout || true
          '''
        }
      }
    }

    stage('Push (non-main branches)') {
      when {
        allOf {
          expression { env.BRANCH_NAME != 'main' }
          not { changeRequest() }
        }
      }
      steps {
        withCredentials([usernamePassword(credentialsId: 'dockerhub-creds', usernameVariable: 'DH_USER', passwordVariable: 'DH_PASS')]) {
          sh '''
            set -e
            echo "$DH_PASS" | docker login -u "$DH_USER" --password-stdin

            SAFE_TAG=$(echo "${BRANCH_SAFE}" | sed 's/[^a-zA-Z0-9_.-]/-/g')
            docker push ${DOCKER_IMAGE}:${SHORT_SHA}
            docker push ${DOCKER_IMAGE}:${SAFE_TAG}

            docker logout || true
          '''
        }
      }
    }

    stage('Deploy (Ansible, main only)') {
      when {
        allOf {
          expression { env.BRANCH_NAME == 'main' }
          not { changeRequest() }
        }
      }
      steps {
        // Клонируем infra с ролями (docker, app_container, nginx_lb)
        dir('infra-src') {
          git url: "${INFRA_REPO_URL}", branch: "${INFRA_BRANCH}"
        }

        // inventory через DNS
        writeFile file: 'inventory.ini', text: "[web]\n${APP_DOMAIN}\n"

        withCredentials([sshUserPrivateKey(credentialsId: 'ec2-ssh-private',
          keyFileVariable: 'SSH_KEY_FILE', usernameVariable: 'SSH_USER')]) {
          dir('infra-src/infrastructure/ansible') {
            sh '''
              set -e
              export ANSIBLE_HOST_KEY_CHECKING=False

              # Ставим именно latest, который запушили buildx-ом
              ansible-playbook -i ../../inventory.ini site.yml \
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