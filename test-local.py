import requests
import json
import time
import subprocess

# Endpoints locais
AUTH_URL = "http://localhost:8001"
FLAGS_URL = "http://localhost:8002"
TARGETING_URL = "http://localhost:8003"
EVALUATION_URL = "http://localhost:8004"
ANALYTICS_URL = "http://localhost:8005"
LOCALSTACK_URL = "http://localhost:4566"

HEADERS = {
    "Authorization": "Bearer local-test-key",
    "Content-Type": "application/json"
}

def print_separator(title):
    print("\n" + "=" * 50)
    print(f" {title} ")
    print("=" * 50)

def check_health():
    print_separator("1. VERIFICANDO HEALTH CHECKS")
    services = {
        "Auth Service": AUTH_URL,
        "Flag Service": FLAGS_URL,
        "Targeting Service": TARGETING_URL,
        "Evaluation Service": EVALUATION_URL,
        "Analytics Service": ANALYTICS_URL
    }
    
    for name, url in services.items():
        try:
            resp = requests.get(f"{url}/health", timeout=3)
            print(f"[{name}] HTTP {resp.status_code}: {resp.json()}")
        except Exception as e:
            print(f"[{name}] FALHA: {e}")

def create_flag():
    print_separator("2. CRIANDO FEATURE FLAG")
    payload = {
        "name": "flag-desconto-progressivo",
        "description": "Habilita desconto progressivo no carrinho",
        "is_enabled": True
    }
    try:
        resp = requests.post(f"{FLAGS_URL}/flags", json=payload, headers=HEADERS)
        print(f"Status Code: {resp.status_code}")
        print(f"Response: {json.dumps(resp.json(), indent=2)}")
    except Exception as e:
        print(f"Erro: {e}")

def create_rule():
    print_separator("3. CRIANDO REGRA DE TARGETING")
    payload = {
        "flag_name": "flag-desconto-progressivo",
        "rules": {
            "type": "PERCENTAGE",
            "value": 75.0
        },
        "is_enabled": True
    }
    try:
        resp = requests.post(f"{TARGETING_URL}/rules", json=payload, headers=HEADERS)
        print(f"Status Code: {resp.status_code}")
        print(f"Response: {json.dumps(resp.json(), indent=2)}")
    except Exception as e:
        print(f"Erro: {e}")

def evaluate_flags():
    print_separator("4. AVALIANDO FEATURE FLAGS (EVALUATION)")
    # Vamos avaliar para 10 usuários diferentes
    results = {}
    for i in range(1, 11):
        user_id = f"user-id-{i}"
        url = f"{EVALUATION_URL}/evaluate?user_id={user_id}&flag_name=flag-desconto-progressivo"
        try:
            resp = requests.get(url)
            data = resp.json()
            results[user_id] = data.get("result")
            print(f"User: {user_id} | Result: {data.get('result')}")
        except Exception as e:
            print(f"Erro para {user_id}: {e}")
    
    true_count = sum(1 for val in results.values() if val is True)
    print(f"\nResumo da amostragem: {true_count} de 10 usuários receberam TRUE (~75% configurado)")

def verify_dynamodb():
    print_separator("5. VERIFICANDO PERSISTÊNCIA NO DYNAMODB (LOCALSTACK)")
    print("Aguardando 3 segundos para o processamento assíncrono do SQS/Analytics...")
    time.sleep(3)
    
    try:
        # Usa o comando do aws-cli para fazer scan na tabela do localstack
        cmd = [
            "docker", "compose", "exec", "-T", "localstack",
            "awslocal", "dynamodb", "scan",
            "--table-name", "analytics-events"
        ]
        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode == 0:
            data = json.loads(result.stdout)
            items = data.get("Items", [])
            print(f"Total de itens salvos no DynamoDB: {len(items)}")
            if items:
                print("Exemplo de um item persistido:")
                print(json.dumps(items[0], indent=2))
        else:
            print("Erro ao ler do DynamoDB via CLI:")
            print(result.stderr)
    except Exception as e:
        print(f"Falha ao executar comando CLI: {e}")

if __name__ == "__main__":
    check_health()
    create_flag()
    create_rule()
    evaluate_flags()
    verify_dynamodb()
