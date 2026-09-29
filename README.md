# .github

Repositório de configuração da organização Cogwyrm Studios no GitHub. O perfil público da organização fica em [`profile/README.md`](profile/README.md), os formulários de issue em [`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE/) e os workflows de CI reutilizáveis em [`.github/workflows/`](.github/workflows/).

## CI reutilizável

Nenhum repositório tem a lógica de CI própria: cada um tem só um `ci.yml` curto que chama os workflows reutilizáveis deste repositório. Este repositório é público, então os repositórios privados da organização podem chamá-los.

### Workflows

| Arquivo | Quem chama | O que faz |
| --- | --- | --- |
| [`checks.yml`](.github/workflows/checks.yml) | todos os repositórios | `gitleaks`, `openspec`, `human-gate` e `rust` |
| [`infra-checks.yml`](.github/workflows/infra-checks.yml) | só o `infra` | `tofu` e `kubeconform` |

Todo job roda sempre e informa um resultado. Quando a verificação não se aplica ao repositório (sem `openspec/`, sem `Cargo.toml`, sem código OpenTofu ou manifestos), o job passa com um aviso em vez de ser pulado. Assim todos os repositórios produzem os mesmos nomes de check, e uma falha anterior nunca é trocada por um "pulado".

### Checks

| Check | O que verifica | Quando não se aplica |
| --- | --- | --- |
| `ci / gitleaks` | Segredos em todo o histórico do git, com o [gitleaks](https://github.com/gitleaks/gitleaks) 8.30.1 (binário da release com checksum SHA-256 conferido). Os valores encontrados saem mascarados no log. Um `.gitleaks.toml` ou `.gitleaksignore` na raiz do repositório é usado automaticamente. | Nunca: roda em todo repositório. |
| `ci / openspec` | `openspec validate --all --strict` com o [OpenSpec](https://github.com/Fission-AI/OpenSpec) 1.13.2, sem telemetria. O CLI e todas as dependências dele vêm do lockfile em [`tools/openspec/`](tools/openspec/), instalados com `npm ci --ignore-scripts`. | Sem pasta `openspec/`. |
| `ci / human-gate` | Portão de aprovação humana (veja abaixo). | Fora de pull request. |
| `ci / rust` | `cargo fmt --check`, `cargo clippy --locked --all-targets -- -D warnings` e `cargo test --locked`. Usa o `rust-toolchain.toml` do repositório, se houver; senão, o stable da imagem do runner. | Sem `Cargo.toml` no diretório configurado. |
| `infra / tofu` | `tofu fmt -check -recursive` e `tofu validate` em cada diretório com `.tf` dentro de `tofu/`, sem backend e sem credenciais. Diretórios com `.terraform.lock.hcl` têm que bater com ele. | Sem código OpenTofu. |
| `infra / kubeconform` | Manifestos Kubernetes com o [kubeconform](https://github.com/yannh/kubeconform) 0.8.0 (checksum conferido), em modo estrito. Arquivos `*.sops.yaml`, `*.enc.yaml` e `kustomization.yaml` ficam de fora; recursos sem schema publicado (Argo CD, Agones) são contados como pulados. | Sem manifestos nos diretórios configurados. |

Os nomes seguem o padrão `<job do caller> / <job do workflow reutilizável>`. Por isso o job do caller se chama `ci` (e `infra`, no `infra`), e não pode mudar sem mudar os rulesets.

**Checks exigidos pelo ruleset em todos os repositórios:**

- `ci / gitleaks`
- `ci / openspec`
- `ci / human-gate`
- `ci / rust`

No `infra`, também `infra / tofu` e `infra / kubeconform`.

### Portão de aprovação humana

O `human-gate` falha quando o pull request mexe num caminho protegido, a menos que tenha a label `human-approved` colocada por uma pessoa. Label colocada por um bot (GitHub App dos agentes) não vale. O check roda de novo quando labels são colocadas ou tiradas, então basta colocar a label para liberar o merge. A label só vale se foi colocada depois do último push: commits novos (ou um force push) invalidam a aprovação, e o portão pede para tirar e colocar a label de novo depois de revisar. O momento do push é o mais recente entre a primeira execução de workflow do commit do head **neste PR** (evento `pull_request`, mesma branch e ligada a este PR, criada pelo próprio push) e o último force push. Execuções do mesmo commit em outra branch ou outro PR não contam, para que um fast-forward para um commit antigo não herde a aprovação. Sem execução correspondente, o portão falha. A data do commit não é usada, porque quem faz o commit escolhe a data.

Se a API do GitHub falhar, o portão falha; ele nunca passa por padrão. Também falha se o PR mexe em 3000 arquivos ou mais (o limite da API que lista os arquivos): nesse caso, divida o PR.

Caminhos protegidos por padrão:

- **Lockfiles** (dependências novas): `Cargo.lock`, `package-lock.json`, `npm-shrinkwrap.json`, `pnpm-lock.yaml`, `yarn.lock`, `bun.lock`, `bun.lockb`, `.terraform.lock.hcl`, `go.sum`, `poetry.lock`, `uv.lock`, `Pipfile.lock`, `Gemfile.lock`, `composer.lock` e `flake.lock`.
- **Manifestos de dependência e toolchain:** `Cargo.toml`, `package.json`, `pyproject.toml`, `requirements*.txt`, `constraints*.txt`, `Pipfile`, `setup.py`, `setup.cfg`, `go.mod`, `Gemfile`, `composer.json`, `flake.nix`, `rust-toolchain`, `rust-toolchain.toml`, `.npmrc`, `.yarnrc`, `.yarnrc.yml`, `.tool-versions` e a pasta `.cargo/`.
- **OpenTofu:** todo `*.tf.json` e `*.tofu.json`; e arquivo `.tf` ou `.tofu` cujo diff adiciona ou remove uma linha com `source =`, `version =`, `required_version` ou `required_providers` em qualquer posição (inclusive blocos numa linha só, como `aws = { source = "...", version = "..." }`). Se o GitHub não mostrar o diff do arquivo, ele conta como protegido.
- **CI e regras de varredura:** tudo em `.github/` (inclusive os workflows, para que um PR não troque o próprio portão), `.gitleaks.toml` e `.gitleaksignore`.
- **Cifragem de segredos:** `.sops.yaml`.
- **Autenticação:** pastas `auth/`, `oauth/`, `authentication/` e `login/`, e arquivos `auth.*`, `auth_*`, `*_auth.*` e `oauth*`.
- **Pagamentos:** pastas `payment/`, `payments/`, `billing/`, `purchase/` e `purchases/`, e arquivos `payment*`, `*_payment*` e `billing*`.

A comparação não diferencia maiúsculas de minúsculas. Um padrão sem `/` compara com o nome do arquivo em qualquer pasta; com `/`, compara com o caminho inteiro, e `*` também atravessa pastas. Arquivos renomeados contam também pelo caminho antigo.

Cada repositório acrescenta os seus padrões pelo input `protected-paths`, um por linha (`#` começa um comentário).

### Como usar

`ci.yml` de um repositório comum:

```yaml
name: ci

on:
  pull_request:
    types: [opened, synchronize, reopened, labeled, unlabeled]

permissions:
  actions: read
  contents: read
  pull-requests: read

concurrency:
  group: ci-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  ci:
    uses: Cogwyrm-Studios/.github/.github/workflows/checks.yml@main
    # Opcional:
    # with:
    #   rust-directory: rust
    #   protected-paths: |
    #     deploy/secrets/*
```

`ci.yml` do `infra`:

```yaml
name: ci

on:
  pull_request:
    types: [opened, synchronize, reopened, labeled, unlabeled]

permissions:
  actions: read
  contents: read
  pull-requests: read

concurrency:
  group: ci-${{ github.event.pull_request.number }}
  cancel-in-progress: true

jobs:
  ci:
    uses: Cogwyrm-Studios/.github/.github/workflows/checks.yml@main
  infra:
    uses: Cogwyrm-Studios/.github/.github/workflows/infra-checks.yml@main
```

O `ci.yml` deste repositório chama a cópia local (`./.github/workflows/checks.yml`), para que um PR aqui rode a versão que ele muda.

### Inputs

`checks.yml`:

| Input | Padrão | Para quê |
| --- | --- | --- |
| `rust-directory` | `.` | Pasta com o `Cargo.toml` (crate ou workspace). |
| `protected-paths` | vazio | Padrões extras do portão humano, um por linha. |

`infra-checks.yml`:

| Input | Padrão | Para quê |
| --- | --- | --- |
| `tofu-version` | `1.12.6` | Versão do OpenTofu; igual ao `required_version` do código. |
| `tofu-directory` | `tofu` | Pasta do código OpenTofu. |
| `kubernetes-paths` | `clusters apps platform manifests` | Pastas com manifestos, separadas por espaço; as que não existem são ignoradas. |
| `kubernetes-version` | `1.37.0` | Versão do Kubernetes dos schemas. |

### Limite conhecido: o caller pode ser trocado

O ruleset só confere o nome do check, e o workflow que roda num PR é o do próprio PR. Um PR pode trocar o `ci.yml` por outro com jobs de mesmo nome que só passam. O portão protege `.github/`, mas quem roda é o portão do PR. Por isso, mudanças em `.github/` só entram com revisão atenta do Denilson.

A regra de ruleset "Require workflows to pass before merging", que resolveria isso, só existe no GitHub Enterprise Cloud. Mesmo lá, ela ignora `types` e não roda em `labeled`/`unlabeled`. Mitigação prevista no plano Team:

- **GitHub App dos agentes sem a permissão "Workflows":** o GitHub recusa push de App sem essa permissão que mexa em `.github/workflows/`, em qualquer repositório, inclusive neste, que é público.
- **Push ruleset "Restrict file paths" em `.github/workflows/**`** nos repositórios privados, com bypass só para o Denilson.

Um caller sem `labeled` e `unlabeled` em `types` nunca libera um PR protegido: colocar a label não roda o portão de novo, e o check continua falhando até outro push, que por sua vez invalida a label. Use sempre o caller documentado abaixo.

### Segurança e custo

- Permissões mínimas, todas de leitura: `contents: read` e, só no `human-gate`, `pull-requests: read` (arquivos, labels e eventos do PR) e `actions: read` (quando o head chegou). O caller precisa conceder as três. Nenhum segredo, nenhum `pull_request_target`, checkout sem credenciais persistidas.
- Actions fixadas por SHA de commit, com a versão num comentário. Binários (gitleaks, kubeconform) fixados por versão e conferidos por SHA-256. OpenSpec fixado por lockfile, sem scripts de instalação.
- Só roda em pull request, não em push na `main` (que só muda por PR). Jobs leves, com cache do cargo no `rust`.

### Atualizar uma versão

1. Mude a versão e, nos binários, o SHA-256 (tirado do arquivo de checksums da release e conferido com `sha256sum` no arquivo baixado).
2. Nas actions, troque o SHA pelo commit da tag nova e atualize o comentário.
3. No OpenSpec, mude a versão em `tools/openspec/package.json` e no `OPENSPEC_VERSION` do `checks.yml`, e regenere o lockfile com `npm install --package-lock-only --ignore-scripts` dentro de `tools/openspec/`.
4. Versão nova de ferramenta ou action é dependência: PR em draft, com aprovação do Denilson.
