# .github

Repositório de configuração da organização Cogwyrm Studios no GitHub. O perfil público da organização fica em [`profile/README.md`](profile/README.md), os formulários de issue em [`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE/) e os workflows de CI reutilizáveis em [`.github/workflows/`](.github/workflows/).

## CI reutilizável

Nenhum repositório tem a lógica de CI própria: cada um tem só um `ci.yml` curto que chama os workflows reutilizáveis deste repositório. Este repositório é público, então os repositórios privados da organização podem chamá-los.

### Workflows

| Arquivo | Quem chama | O que faz |
| --- | --- | --- |
| [`checks.yml`](.github/workflows/checks.yml) | todos os repositórios | `gitleaks`, `openspec`, `human-gate` e `rust` |
| [`infra-checks.yml`](.github/workflows/infra-checks.yml) | só o `infra` | `tofu` e `kubeconform` |
| [`add-to-project.yml`](.github/workflows/add-to-project.yml) | todos os repositórios privados, pelo `project.yml` | Põe a issue ou o PR no [projeto da organização](https://github.com/orgs/Cogwyrm-Studios/projects/1) (veja [Projeto da organização](#projeto-da-organização)) |

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

O `human-gate` falha quando o pull request mexe num caminho protegido, a menos que tenha a label `human-approved` colocada por uma pessoa. Label colocada por um bot (GitHub App dos agentes) não vale. O check roda de novo quando labels são colocadas ou tiradas, então basta colocar a label para liberar o merge. A label só vale se foi colocada depois da última mudança do PR: push de commits novos, force push, volta a um commit anterior ou troca da base. Depois disso, o portão pede para tirar e colocar a label de novo. A última mudança do head é a primeira execução de workflow do SHA atual **neste PR** (evento `pull_request`, mesma branch, ligada a este PR) que vem depois da última execução de qualquer outro SHA. Assim um commit que volta a ser o head, por exemplo por fast-forward, não herda uma aprovação antiga. Force push e troca de base contam pelos eventos `head_ref_force_pushed` e `base_ref_changed` do PR. A data do commit não é usada, porque quem faz o commit escolhe a data. Na dúvida (nenhuma execução correspondente), o portão falha. Os arquivos são sempre comparados com a base atual do PR.

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
    types: [opened, edited, synchronize, reopened, labeled, unlabeled]

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
    types: [opened, edited, synchronize, reopened, labeled, unlabeled]

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

O caller precisa ter em `types` exatamente `opened, edited, synchronize, reopened, labeled, unlabeled`:

- Sem `labeled` e `unlabeled`, o caller nunca libera um PR protegido: colocar a label não roda o portão de novo, e o check continua falhando até outro push, que por sua vez invalida a label.
- Sem `edited`, trocar a base do PR não roda os checks de novo, e o resultado verde do mesmo SHA passa a valer para a base nova.

Até existir o GitHub App dos agentes, também ficam como limite conhecido os contornos que dependem do token do Denilson (que os agentes usam hoje) ou de editar o caller: com esse token, um agente consegue colocar a label como "usuário" ou mudar o `ci.yml`. A proteção, nesse caso, é a revisão do Denilson.

### Segurança e custo

- Nos checks de CI, permissões mínimas, todas de leitura: `contents: read` e, só no `human-gate`, `pull-requests: read` (arquivos, labels e eventos do PR) e `actions: read` (quando o head chegou). O caller precisa conceder as três. Nenhum segredo, nenhum `pull_request_target`, checkout sem credenciais persistidas.
- Actions fixadas por SHA de commit, com a versão num comentário. Binários (gitleaks, kubeconform) fixados por versão e conferidos por SHA-256. OpenSpec fixado por lockfile, sem scripts de instalação.
- Só roda em pull request, não em push na `main` (que só muda por PR). Jobs leves, com cache do cargo no `rust`.

### Atualizar uma versão

1. Mude a versão e, nos binários, o SHA-256 (tirado do arquivo de checksums da release e conferido com `sha256sum` no arquivo baixado).
2. Nas actions, troque o SHA pelo commit da tag nova e atualize o comentário.
3. No OpenSpec, mude a versão em `tools/openspec/package.json` e no `OPENSPEC_VERSION` do `checks.yml`, e regenere o lockfile com `npm install --package-lock-only --ignore-scripts` dentro de `tools/openspec/`.
4. Versão nova de ferramenta ou action é dependência: PR em draft, com aprovação do Denilson.

## Projeto da organização

Toda issue e todo PR de todos os repositórios entram no [projeto 1 da organização](https://github.com/orgs/Cogwyrm-Studios/projects/1) (decisão do Denilson de 2026-10-03). O auto-add nativo dos Projects não serve: no plano Team são só 5 workflows, um por repositório, e ele não pega itens que já existem.

Cada repositório privado tem um `project.yml` que chama o [`add-to-project.yml`](.github/workflows/add-to-project.yml) em `issues` (`opened`, `reopened`) e `pull_request_target` (`opened`, `reopened`). O workflow gera um token do GitHub App `cogwyrm-agents` (com [`actions/create-github-app-token`](https://github.com/actions/create-github-app-token)) e chama a mutation `addProjectV2ItemById` da API GraphQL. Pôr um item que já está no projeto não muda nada. Issue transferida de repositório continua no projeto (o campo `Repository` do item acompanha a issue), então `transferred` não é escutado.

`project.yml` de um repositório:

```yaml
name: project

on:
  issues:
    types: [opened, reopened]
  pull_request_target:
    types: [opened, reopened]

permissions: {}

jobs:
  project:
    uses: Cogwyrm-Studios/.github/.github/workflows/add-to-project.yml@main
    with:
      app-id: ${{ vars.AGENTS_APP_ID }}
    secrets:
      app-private-key: ${{ secrets.AGENTS_APP_PRIVATE_KEY }}
```

Requisitos:

- GitHub App `cogwyrm-agents` com **Organization permissions → Projects: Read and write**, instalado no repositório.
- Variável `AGENTS_APP_ID` e secret `AGENTS_APP_PRIVATE_KEY` da organização liberados para o repositório.

Este repositório não tem caller: é público, e a chave privada do App, que é a credencial mestre dele, não é liberada para repositório público. Os PRs daqui entram no projeto pela carga com `gh`.

Segurança:

- `pull_request_target` roda com segredos mesmo em PR de fork. Por isso o workflow **nunca faz checkout nem roda código do PR**: ele só lê o ID do item no payload do evento, passado por variável de ambiente, nunca interpolado no script.
- O `GITHUB_TOKEN` fica sem nenhuma permissão (`permissions: {}`). O token do App vale só para o repositório do evento e é reduzido a `organization-projects: write`, `issues: read` e `pull-requests: read`; a action revoga o token no fim do job.
- O secret vai explícito para o workflow reutilizável, nunca com `secrets: inherit`.
- Mudar o `add-to-project.yml` ou um `project.yml` passa pelo portão `human-gate`, como todo `.github/`.

Para pôr no projeto o que já existia antes do workflow, rode uma carga com `gh` (token com escopo `project`) e a mesma mutation: ela é idempotente.
