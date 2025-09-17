pipeline {
  agent any

  environment {
    DOCKERHUB_REPO = 'docker.io/<your_dockerhub_user>/simple-web-page'
    AWS_DOMAIN     = 'assugan.click'
    INFRA_REPO_URL = 'https://github.com/assugan/infrastructure.git'
    INFRA_BRANCH   = 'draft-infra'

    TELEGRAM_BOT_TOKEN = credentials('telegram-bot-token')
    TELEGRAM_CHAT_ID   = credentials('telegram-chat-id')
  }

  options { timestamps() }

  stages {
    stage('Checkout app') {
      steps { checkout scm }
    }

    stage('Lint') {
      steps {
        sh '''
          echo "== Dockerfile lint =="
          if command -v hadolint >/dev/null 2>&1; then
            hadolint Dockerfile
          else
            echo "⚠️ hadolint not installed"
          fi

          echo "== YAML lint =="
          if command -v yamllint >/dev/null 2>&1; then
            yamllint -d "{extends: relaxed, rules: {line-length: disable}}" .
          else
            echo "⚠️ yamllint not installed"
          fi
        '''
      }
    }

    stage('Build image') {
      steps {
        script {
          env.IMAGE_TAG = sh(script: "git rev-parse --short=12 HEAD", returnStdout: true).trim()
          if (env.BRANCH_NAME == 'main') {
            env.ADDITIONAL_TAG = 'latest'
          } else {
            env.ADDITIONAL_TAG = env.BRANCH_NAME.replaceAll(/[^a-zA-Z0-9_.-]/, '-')
          }
        }
        sh '''
          docker build -t ${DOCKERHUB_REPO}:${IMAGE_TAG} .
          if [ -n "${ADDITIONAL_TAG}" ]; then
            docker tag ${DOCKERHUB_REPO}:${IMAGE_TAG} ${DOCKERHUB_REPO}:${ADDITIONAL_TAG}
          fi
        '''
      }
    }

    stage('Test image') {
      steps {
        sh '''
          echo "== Run container for test =="
          docker run -d --rm -p 8080:80 --name webtest ${DOCKERHUB_REPO}:${IMAGE_TAG}
          sleep 5
          curl -s -o /tmp/out.html -w "%{http_code}" http://localhost:8080 | tee result.txt
          code=$(cat result.txt)
          docker stop webtest || true

          if [ "$code" -ne 200 ]; then
            echo "❌ Test failed: HTTP $code"
            exit 1
          fi
          echo "✅ Test passed"
        '''
      }
    }

    stage('Push to Docker Hub') {
      steps {
        withCredentials([usernamePassword(credentialsId: 'dockerhub-creds', usernameVariable: 'DH_USER', passwordVariable: 'DH_PASS')]) {
          sh '''
            echo "$DH_PASS" | docker login -u "$DH_USER" --password-stdin
            docker push ${DOCKERHUB_REPO}:${IMAGE_TAG}
            if [ -n "${ADDITIONAL_TAG}" ]; then
              docker push ${DOCKERHUB_REPO}:${ADDITIONAL_TAG}
            fi
            docker logout || true
          '''
        }
      }
    }

    stage('Checkout infra/ansible') {
      steps {
        dir('infra-src') {
          git url: "${INFRA_REPO_URL}", branch: "${INFRA_BRANCH}"
        }
      }
    }

    stage('Deploy via Ansible') {
      steps {
        writeFile file: 'inventory.ini', text: "[web]\n${AWS_DOMAIN}\n"
        withCredentials([sshUserPrivateKey(credentialsId: 'ec2-ssh-private',
          keyFileVariable: 'SSH_KEY_FILE', usernameVariable: 'SSH_USER')]) {

          script {
            env.DEPLOY_TAG = (env.BRANCH_NAME == 'main') ? (env.ADDITIONAL_TAG ?: 'latest') : env.IMAGE_TAG
          }

          dir('infra-src/infrastructure/ansible') {
            sh '''
              ANSIBLE_HOST_KEY_CHECKING=false ansible-playbook -i ../../inventory.ini site.yml \
                -u "$SSH_USER" --private-key "$SSH_KEY_FILE" \
                --extra-vars "app_domain=''' + "${AWS_DOMAIN}" + ''' image_repo=''' + "${DOCKERHUB_REPO}" + ''' image_tag=''' + "${DEPLOY_TAG}" + '''"
            '''
          }
        }
      }
    }
  }

  post {
    success { script { notifyTG("✅ Pipeline OK: ${DOCKERHUB_REPO}:${DEPLOY_TAG} → ${AWS_DOMAIN}") } }
    failure { script { notifyTG("🔥 Pipeline FAILED for ${AWS_DOMAIN}") } }
  }
}

def notifyTG(String msg) {
  withEnv(["MSG=${msg}"]) {
    sh '''curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d chat_id="${TELEGRAM_CHAT_ID}" --data-urlencode "text=${MSG}"'''
  }
}