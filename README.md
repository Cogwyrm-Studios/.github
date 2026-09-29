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
| `ci / openspec` | `openspec validate --all --strict` com o [OpenSpec](https://github.com/Fission-AI/OpenSpec) 1.13.2, sem telemetria. | Sem pasta `openspec/`. |
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

O `human-gate` falha quando o pull request mexe num caminho protegido, a menos que tenha a label `human-approved` colocada por uma pessoa. Label colocada por um bot (GitHub App dos agentes) não vale. O check roda de novo quando labels são colocadas ou tiradas, então basta colocar a label para liberar o merge.

Caminhos protegidos por padrão:

- **Lockfiles** (dependências novas): `Cargo.lock`, `package-lock.json`, `npm-shrinkwrap.json`, `pnpm-lock.yaml`, `yarn.lock`, `bun.lock`, `bun.lockb`, `.terraform.lock.hcl`, `go.sum`, `poetry.lock`, `uv.lock`, `Pipfile.lock`, `Gemfile.lock`, `composer.lock` e `flake.lock`.
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

### Segurança e custo

- Permissões mínimas: `contents: read` e, só no `human-gate`, `pull-requests: read`. Nenhum segredo, nenhum `pull_request_target`, checkout sem credenciais persistidas.
- Actions fixadas por SHA de commit, com a versão num comentário. Binários (gitleaks, kubeconform) fixados por versão e conferidos por SHA-256.
- Só roda em pull request, não em push na `main` (que só muda por PR). Jobs leves, com cache do cargo no `rust`.

### Atualizar uma versão

1. Mude a versão e, nos binários, o SHA-256 (tirado do arquivo de checksums da release e conferido com `sha256sum` no arquivo baixado).
2. Nas actions, troque o SHA pelo commit da tag nova e atualize o comentário.
3. Versão nova de ferramenta ou action é dependência: PR em draft, com aprovação do Denilson.
