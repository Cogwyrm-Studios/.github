# .github

Repositório de configuração da organização Cogwyrm Studios no GitHub. O perfil público da organização fica em [`profile/README.md`](profile/README.md), o formulário de issue em [`.github/ISSUE_TEMPLATE/`](.github/ISSUE_TEMPLATE/) (só o PRD: toda issue é um PRD, [ADR 0025](https://github.com/Cogwyrm-Studios/handbook/blob/main/decisions/0025-toda-issue-e-um-prd.md), e issue em branco fica desligada) e os workflows de CI reutilizáveis em [`.github/workflows/`](.github/workflows/).

## CI reutilizável

Nenhum repositório tem a lógica de CI própria: cada um tem só um `ci.yml` curto que chama os workflows reutilizáveis deste repositório. Este repositório é público, então os repositórios privados da organização podem chamá-los.

### Workflows

| Arquivo | Quem chama | O que faz |
| --- | --- | --- |
| [`checks.yml`](.github/workflows/checks.yml) | todos os repositórios | `gitleaks`, `openspec`, `human-gate`, `rust` e `deny` |
| [`infra-checks.yml`](.github/workflows/infra-checks.yml) | só o `infra` | `tofu` e `kubeconform` |
| [`add-to-project.yml`](.github/workflows/add-to-project.yml) | todos os repositórios privados, pelo `project.yml` | Põe a issue ou o PR no [projeto da organização](https://github.com/orgs/Cogwyrm-Studios/projects/1) (veja [Projeto da organização](#projeto-da-organização)) |

Em pull request, todo job roda sempre e informa um resultado (na execução diária agendada, só o `deny` trabalha; veja [Execução diária](#execução-diária)). Quando a verificação não se aplica ao repositório (sem `openspec/`, sem `Cargo.toml`, sem código OpenTofu ou manifestos), o job passa com um aviso em vez de ser pulado. Assim todos os repositórios produzem os mesmos nomes de check, e uma falha anterior nunca é trocada por um "pulado".

### Checks

| Check | O que verifica | Quando não se aplica |
| --- | --- | --- |
| `ci / gitleaks` | Segredos em todo o histórico do git, com o [gitleaks](https://github.com/gitleaks/gitleaks) 8.30.1 (binário da release com checksum SHA-256 conferido). Os valores encontrados saem mascarados no log. Um `.gitleaks.toml` ou `.gitleaksignore` na raiz do repositório é usado automaticamente. | Nunca: roda em todo repositório. |
| `ci / openspec` | `openspec validate --all --strict` com o [OpenSpec](https://github.com/Fission-AI/OpenSpec) 1.13.2, sem telemetria. O CLI e todas as dependências dele vêm do lockfile em [`tools/openspec/`](tools/openspec/), instalados com `npm ci --ignore-scripts`. | Sem pasta `openspec/`. |
| `ci / human-gate` | Portão de aprovação humana (veja abaixo). | Fora de pull request. |
| `ci / rust` | `cargo fmt --check`, `cargo clippy --locked --all-targets -- -D warnings` e `cargo test --locked`. Usa o `rust-toolchain.toml` do repositório, se houver; senão, o stable da imagem do runner. | Sem `Cargo.toml` no diretório configurado. |
| `ci / deny` | Cadeia de suprimentos do Rust ([orrery#49-D2](https://github.com/Cogwyrm-Studios/orrery/issues/49)): `cargo deny --locked check advisories licenses bans sources` com o [cargo-deny](https://github.com/EmbarkStudios/cargo-deny) 0.20.2 (binário da release com checksum SHA-256 conferido) e o `deny.toml` do repositório; qualquer erro de qualquer das quatro verificações bloqueia. **Falha se houver `Cargo.toml` sem `deny.toml`** no mesmo diretório. Depois, o passo dos avisos do quinn (veja [Avisos de segurança do quinn](#avisos-de-segurança-do-quinn)), que roda mesmo se o `cargo deny` falhar e aceita exceções revisadas em `advisory-exceptions.json`. | Sem `Cargo.toml` no diretório configurado. |
| `infra / tofu` | `tofu fmt -check -recursive` e `tofu validate` em cada diretório com `.tf` dentro de `tofu/`, sem backend e sem credenciais. Diretórios com `.terraform.lock.hcl` têm que bater com ele. | Sem código OpenTofu. |
| `infra / kubeconform` | Manifestos Kubernetes com o [kubeconform](https://github.com/yannh/kubeconform) 0.8.0 (checksum conferido), em modo estrito. Arquivos `*.sops.yaml`, `*.enc.yaml` e `kustomization.yaml` ficam de fora; recursos sem schema publicado (Argo CD, Agones) são contados como pulados. | Sem manifestos nos diretórios configurados. |

Os nomes seguem o padrão `<job do caller> / <job do workflow reutilizável>`. Por isso o job do caller se chama `ci` (e `infra`, no `infra`), e não pode mudar sem mudar os rulesets.

**Checks exigidos pelo ruleset em todos os repositórios:**

- `ci / gitleaks`
- `ci / openspec`
- `ci / human-gate`
- `ci / rust`
- `ci / deny` (a adicionar pelo Denilson, veja abaixo)

No `infra`, também `infra / tofu` e `infra / kubeconform`.

#### Adicionar `ci / deny` ao ruleset

O ruleset `require-ci` é da organização e vale para todos os repositórios (`~ALL`, branch padrão). Só o Denilson muda ruleset, e na ordem certa:

1. O `deny.toml` do orrery já está na `main` dele (sem ele, o `ci / deny` do orrery falha).
2. O PR que cria o job `deny` entrou na `main` deste repositório. A partir daí todo caller passa a produzir `ci / deny` (os repositórios sem `Cargo.toml` passam com aviso).
3. Em **Organization settings → Repository → Rulesets → `require-ci` → Require status checks to pass → Add checks**, digite `ci / deny` e escolha a origem **GitHub Actions**; salve.

PR aberto antes do passo 2 não tem o check até rodar de novo: um push ou fechar e reabrir o PR resolve.

Pela API, o equivalente (conferir a lista atual antes, porque o `PUT` substitui as regras):

```sh
gh api orgs/Cogwyrm-Studios/rulesets/24209924 > require-ci.json
# acrescentar {"context": "ci / deny", "integration_id": 15368} em
# rules[type=required_status_checks].parameters.required_status_checks
gh api -X PUT orgs/Cogwyrm-Studios/rulesets/24209924 --input require-ci.json
```

### Portão de aprovação humana

O `human-gate` falha quando o pull request mexe num caminho protegido, a menos que tenha a label `human-approved` colocada por uma pessoa. Label colocada por um bot (GitHub App dos agentes) não vale. O check roda de novo quando labels são colocadas ou tiradas, então basta colocar a label para liberar o merge. A label só vale se foi colocada depois da última mudança do PR: push de commits novos, force push, volta a um commit anterior ou troca da base. Depois disso, o portão pede para tirar e colocar a label de novo. A última mudança do head é a primeira execução de workflow do SHA atual **neste PR** (evento `pull_request`, mesma branch, ligada a este PR) que vem depois da última execução de qualquer outro SHA. Assim um commit que volta a ser o head, por exemplo por fast-forward, não herda uma aprovação antiga. Force push e troca de base contam pelos eventos `head_ref_force_pushed` e `base_ref_changed` do PR. A data do commit não é usada, porque quem faz o commit escolhe a data. Na dúvida (nenhuma execução correspondente), o portão falha. Os arquivos são sempre comparados com a base atual do PR. Independente da label, o portão também falha com link simbólico ou submódulo num local do Claude Code (veja [Links simbólicos e submódulos no Claude Code](#links-simbólicos-e-submódulos-no-claude-code)).

Se a API do GitHub falhar, o portão falha; ele nunca passa por padrão. Também falha se o PR mexe em 3000 arquivos ou mais (o limite da API que lista os arquivos): nesse caso, divida o PR. E falha se o nome de um arquivo do PR (atual ou anterior, num rename) tiver caractere de controle, como quebra de linha ou tab, porque o nome se partiria e esconderia um caminho protegido: renomeie o arquivo.

Caminhos protegidos por padrão:

- **Lockfiles** (dependências novas): `Cargo.lock`, `package-lock.json`, `npm-shrinkwrap.json`, `pnpm-lock.yaml`, `yarn.lock`, `bun.lock`, `bun.lockb`, `.terraform.lock.hcl`, `go.sum`, `poetry.lock`, `uv.lock`, `Pipfile.lock`, `Gemfile.lock`, `composer.lock` e `flake.lock`.
- **Manifestos de dependência e toolchain:** `Cargo.toml`, `package.json`, `pyproject.toml`, `requirements*.txt`, `constraints*.txt`, `Pipfile`, `setup.py`, `setup.cfg`, `go.mod`, `Gemfile`, `composer.json`, `flake.nix`, `rust-toolchain`, `rust-toolchain.toml`, `.npmrc`, `.yarnrc`, `.yarnrc.yml`, `.tool-versions` e a pasta `.cargo/`.
- **OpenTofu:** todo `*.tf.json` e `*.tofu.json`; e arquivo `.tf` ou `.tofu` cujo diff adiciona ou remove uma linha com `source =`, `version =`, `required_version` ou `required_providers` em qualquer posição (inclusive blocos numa linha só, como `aws = { source = "...", version = "..." }`). Se o GitHub não mostrar o diff do arquivo, ele conta como protegido.
- **CI e regras de varredura:** tudo em `.github/` (inclusive os workflows, para que um PR não troque o próprio portão), `.gitleaks.toml` e `.gitleaksignore`.
- **Cifragem de segredos:** `.sops.yaml`.
- **Política da cadeia de suprimentos:** `deny.toml` (licenças, crates banidas, origens e avisos ignorados do `cargo-deny`) e `advisory-exceptions.json` (exceções do passo dos avisos do quinn).
- **Claude Code:** o que roda comandos ou concede permissões em toda sessão de toda máquina que puxa o repositório. Na raiz ou em qualquer pasta:
  - `.claude/settings*.json` (inclusive `settings.local.json`) e tudo em `.claude/hooks/` (inclusive `.claude` ou `.claude/hooks` trocados por link simbólico);
  - hooks de plugin (`hooks/hooks.json`) e manifestos (`.claude-plugin/`, cujo `plugin.json` aceita `hooks` e `mcpServers`, e o `marketplace.json`);
  - servidores MCP e LSP (`.mcp.json` e `.lsp.json`) e monitores de plugin (`monitors/monitors.json`);
  - todo arquivo que não seja `.md` sob uma pasta `.claude/` (por exemplo os scripts ao lado de skills, agentes e comandos) ou num plugin em `plugins/<nome>/` (scripts que os hooks e servidores rodam por `${CLAUDE_PLUGIN_ROOT}`, `bin/`, que vai para o `PATH` da ferramenta Bash, e o `settings.json`);
  - `memory/RULES.md`, injetado em todo prompt pelo hook do workspace.
- **Instruções do Claude Code:** todo `.md` sob `.claude/` ou em `plugins/<nome>/` (skills, agentes e comandos, na raiz ou aninhados). O frontmatter deles aceita `hooks`, `mcpServers`, `permissionMode` e `allowed-tools`, e o corpo roda comandos com `` !`comando` `` e blocos ` ```! `. O arquivo fica protegido quando:
  - uma linha adicionada ou removida cai **dentro do frontmatter** ou **dentro de um bloco ` ```! `** (ou `~~~!`), no arquivo antes ou depois da mudança. Isso inclui editar o comando de um hook que já existe, uma lista de `allowed-tools` e o corpo de um bloco ` ```! ` já aprovado. Como toda skill e todo agente têm frontmatter (`name`, `description`), criar ou apagar um deles também pede a label. Frontmatter é o trecho entre um `---` na primeira linha e o `---` seguinte (BOM e CRLF aceitos); sem fechamento, vai até o fim do arquivo, assim como um bloco sem fechamento. Os limites vêm do conteúdo do arquivo na base do PR (merge base) e no head, lido pela API;
  - ou uma linha adicionada ou removida, em qualquer parte do arquivo, tem uma dessas chaves em qualquer posição (inclusive entre aspas ou num mapa `{...}`), um comando embutido, um escape hexadecimal do YAML (`\x..`, `\u....`, que esconderia o nome da chave), uma chave explícita (`? `), uma âncora (`&nome`) ou um alias (`*nome :` como chave, `: *nome` como valor);
  - ou o arquivo foi renomeado ou copiado, porque o diff não mostra o frontmatter que mudou de lugar (um agente de plugin ignora `hooks`; o mesmo arquivo em `.claude/agents/` os executa);
  - ou não há diff (arquivo grande ou binário), ou o conteúdo não pôde ser lido.

  Mudança só no corpo, fora de bloco ` ```! `, e sem as marcas acima não pede a label.
- **Autenticação:** pastas `auth/`, `oauth/`, `authentication/` e `login/`, e arquivos `auth.*`, `auth_*`, `*_auth.*` e `oauth*`.
- **Pagamentos:** pastas `payment/`, `payments/`, `billing/`, `purchase/` e `purchases/`, e arquivos `payment*`, `*_payment*` e `billing*`.

A comparação não diferencia maiúsculas de minúsculas. Um padrão sem `/` compara com o nome do arquivo em qualquer pasta; com `/`, compara com o caminho inteiro, e `*` também atravessa pastas. Arquivos renomeados contam também pelo caminho antigo.

Cada repositório acrescenta os seus padrões pelo input `protected-paths`, um por linha (`#` começa um comentário).

#### Regras para o Claude Code

O portão só protege o que está nos caminhos acima. Para que isso baste:

- **Um hook não executa nem faz `source` de nada fora de `.claude/hooks/`** (no plugin, fora da pasta dele). O mesmo vale para todo comando que a configuração versionada manda rodar: `statusLine`, servidores MCP e LSP, monitores, hooks no frontmatter e os comandos `` !`...` `` e ` ```! ` das skills, que só chamam scripts de pastas protegidas (`.claude/` ou o plugin). Programas instalados no sistema (`git`, `jq`) podem ser chamados; scripts e configuração de outras pastas do repositório, não.
- **O que um hook injeta no contexto fica num caminho protegido**, como o `memory/RULES.md` lido pelo hook do workspace. Arquivo novo injetado por um hook entra na lista de caminhos protegidos no mesmo PR.
- **O `plugin.json` aponta só para os locais padrão** (`hooks/hooks.json`, `.mcp.json`, `.lsp.json`, `skills/`, `agents/`, `commands/`). Um arquivo de hooks ou de servidores fora deles não é protegido depois do PR que o referencia.

Quem revisa um PR com a label confere essas regras: o portão não lê o conteúdo dos scripts.

#### Links simbólicos e submódulos no Claude Code

O passo `Check Claude Code symlinks and submodules` falha, **com ou sem a label**, se a árvore do head do PR tiver um link simbólico (modo `120000` no git) ou um submódulo (modo `160000`) num local do Claude Code: `.claude/` e `.claude-plugin/` (inclusive as próprias pastas), `plugins/`, `hooks/hooks.json` (e a pasta `hooks` na raiz), `.mcp.json`, `.lsp.json`, `monitors/`, `memory/RULES.md` e a pasta `memory`, na raiz ou em qualquer pasta. Um link nesses locais faria um caminho não protegido valer como protegido: um PR mudaria o alvo sem passar pelo portão. Um submódulo traria arquivos de outro repositório, e trocar o commit dele mudaria esses arquivos sem que o diff os mostre. A árvore inteira é verificada, não só os arquivos do PR, porque um link já existente deixaria passar uma mudança no alvo.

A única exceção é um link dentro de uma pasta `.claude/hooks/` que, seguido pela árvore do head como o sistema de arquivos faria (inclusive por links no meio do caminho, como uma pasta que é link), termina num **arquivo comum** (modo `100644` ou `100755`) dentro dessa mesma pasta (a mais interna, se houver uma dentro de outra). Falham o alvo absoluto, o `..` acima da raiz, o alvo inexistente, o que termina numa pasta, o que usa um arquivo como pasta, o que passa por submódulo, o laço de links (mais de 40) e o caminho ambíguo (dois arquivos que só diferem em maiúsculas e minúsculas).

**Link legítimo também trava.** Um link em `*/memory`, em `*/plugins/*` ou em outro desses locais, mesmo com motivo legítimo, faz o passo falhar em todo PR do repositório enquanto existir, e a label não libera. Esse é o caminho esperado: trocar o link por um arquivo comum ou mudar a lista de locais neste workflow central, por PR no `.github`, que passa pelo próprio portão.

O passo faz um checkout esparso só das árvores do commit (`--filter=blob:none`, nenhum arquivo no disco; nada do PR é executado), lê modos e caminhos com `git ls-tree` e busca pela API (`git/blobs`) só o conteúdo dos links que precisa seguir. A comparação ignora maiúsculas e minúsculas, porque o macOS lê `.Claude` como `.claude`.

#### Testes do portão

[`tools/human-gate/test.sh`](tools/human-gate/test.sh) extrai do `checks.yml` os scripts dos dois passos do `human-gate` e os roda contra repositórios git locais, com um substituto do `gh api` ([`gh`](tools/human-gate/gh)) e a lista de arquivos do PR gerada de diffs reais no formato da API ([`files.py`](tools/human-gate/files.py)). Cobre os caminhos protegidos, o frontmatter, os blocos ` ```! `, renames, remoções, nomes com caractere de controle, links e submódulos. O job `human-gate-tests` do `ci.yml` deste repositório roda os testes em todo PR daqui; ele não existe nos callers. Precisa de `bash`, `git`, `jq`, `python3` e `awk`.

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

#### Execução diária

Avisos de segurança aparecem sem nenhum commit. Para o `ci / deny` acusar um aviso novo mesmo sem PR aberto, todo repositório com `Cargo.toml` acrescenta um `schedule` ao `on:` do seu `ci.yml` (hoje, só o `orrery`):

```yaml
on:
  pull_request:
    types: [opened, edited, synchronize, reopened, labeled, unlabeled]
  schedule:
    # Todo dia às 09:17 UTC (06:17 em Brasília), fora da hora cheia.
    - cron: "17 9 * * *"
```

- A execução agendada roda na branch padrão. Nela, só o job `deny` trabalha: `gitleaks`, `openspec` e `rust` ficam pulados (nada mudou no código) e o `human-gate` passa com aviso. Ruleset não se aplica a execução agendada, então os pulados não bloqueiam nada.
- Falha em execução agendada manda e-mail para quem por último mexeu na linha do `cron` no `ci.yml` (comportamento do GitHub), além de aparecer na aba Actions.
- O `concurrency` do caller continua como está: sem PR, o grupo fica `ci-` e só existe uma execução agendada por vez.
- Mudar o `ci.yml` do caller passa pelo `human-gate` (é `.github/`).

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

### Avisos de segurança do quinn

O `cargo-deny` só lê a [RustSec](https://rustsec.org/), e o quinn publica a maior parte dos avisos dele só como GHSA no próprio repositório. Em 2026-10-04, dos 11 avisos que o quinn publicou em 2026, só 2 estavam na RustSec (base de 2026-10-03: RUSTSEC-2026-0037 e RUSTSEC-2026-0185) e só esses mesmos 2 no banco global do GitHub. Os outros 9 Dependabot e `osv-scanner` também não veem. Por isso o job `deny` tem um passo próprio, [`tools/repo-advisories/check.sh`](tools/repo-advisories/check.sh), só com `bash`, `curl`, `awk`, `date` e `jq`, todos da imagem do runner.

#### O que o passo faz

1. Lê do `Cargo.lock` as versões travadas de `quinn`, `quinn-proto` e `quinn-udp`. Se nenhum deles estiver no lock, termina com aviso, sem chamar a API.
2. Lê todos os avisos publicados de `repos/quinn-rs/quinn/security-advisories` (`state=published`, seguindo a paginação por cursor), com o `GITHUB_TOKEN` do workflow. Se a API recusar o token (401, 403 ou 404), repete sem autenticação, com um aviso no log.
3. Confere a resposta: menos avisos que o mínimo conhecido (`MIN_ADVISORIES`, 13 em 2026-10-04; aviso é retirado, nunca apagado) falha. Aviso retirado (`withdrawn_at`) fica de fora. Aviso publicado sem pacote, ou com algum pacote que não seja exatamente do ecossistema `rust`, gera um erro do aviso inteiro; as entradas Rust utilizáveis desse aviso continuam sendo avaliadas.
4. Classifica cada versão travada de cada aviso, como abaixo.

As faixas e as correções são texto livre digitado pelos mantenedores. O script aceita estas formas e recusa o resto:

| Forma | Leitura |
| --- | --- |
| `>= 0.11.0, <= 0.11.18` | vírgula junta restrições (sintaxe do GHSA, E) |
| `0.11.17` ou `= 0.11.13` | versão exata |
| `0.11.0 - 0.11.6` | faixa inclusiva (com espaços em volta do hífen) |
| `< 0.5.16, >= 0.6.0 < 0.6.3` | o E é vazio, então os grupos separados por vírgula são alternativas (OU), que é o que o aviso quis dizer |
| `0.9.5, 0.10.5` ou `>= 0.11.19` (correção) | primeira versão corrigida de cada linha semver compatível (mesmo major; abaixo de 1.0, mesmo minor) |

Recusados, com falha: pré-release ou metadado de build (`0.11.7-rc.1`, e `0.11.0-0.11.6` sem espaços, que parece pré-release); versão parcial depois de `=`, sem operador, depois de `<=` ou depois de `>` (`= 0.11`, `0.11`, `<= 0.11`, `> 0.11`, todos ambíguos); qualquer outro operador (`^0.11`, `~0.11`). Versão parcial depois de `<` ou `>=` é completada com zeros, o que é exato (`< 0.12` é `< 0.12.0`). Mais de uma correção para a mesma linha também falha.

Classificação de uma versão travada:

| Situação | Resultado |
| --- | --- |
| abaixo da correção listada para a própria linha, dentro ou fora da faixa | **afetada** (exit 1) |
| na correção da própria linha ou acima dela | limpa, mesmo dentro de uma faixa sem limite de cima (`> 0.7.0`) |
| na correção da própria linha ou acima dela, mas dentro de uma faixa com limite de cima (`<`, `<=` ou `=`) | **erro** (exit 2): o aviso se contradiz |
| dentro da faixa, sem nenhuma correção publicada | **afetada** (exit 1) |
| dentro da faixa, com correções só para outras linhas | **não resolvida** (exit 2): o aviso não diz se a linha está corrigida |
| fora da faixa e sem correção para a própria linha | limpa |

O caso "não resolvida" é o de uma linha nova, por exemplo `quinn-proto` 0.12 diante de GHSA-465w (`> 0.7.0`, corrigido em `>= 0.11.18`) ou GHSA-qfwj (`>= 0.11.15`, corrigido em `0.11.17`). Ele só passa com uma exceção revisada.

O passo **falha fechado**: falha da API, resposta curta, aviso sem pacote Rust utilizável, faixa ou correção recusada, versão não resolvida e exceção inválida, vencida ou sem uso falham o check (exit 2). Nenhum desses casos passa por padrão.

#### Exceções revisadas

Uma exceção fica no repositório que consome o workflow, em `advisory-exceptions.json`, ao lado do `Cargo.toml` (no `rust-directory`). É caminho protegido do `human-gate`, então toda exceção passa pela revisão do Denilson, como um `ignore` do `deny.toml`.

```json
{
  "exceptions": [
    {
      "advisory": "GHSA-465w-v9q3-7j98",
      "kind": "UNRESOLVED",
      "crate": "quinn-proto",
      "version": "0.12.0",
      "reason": "Explica por que a versão não é afetada, com a fonte (commit, release notes).",
      "review-by": "2026-12-01"
    }
  ]
}
```

- Cada exceção vale para um GHSA, um tipo de achado (`kind`: `AFFECTED`, `UNRESOLVED` ou `ERROR`), um crate e **uma versão exata**. Atualizar o crate, ou o achado mudar de tipo (por exemplo, de `UNRESOLVED` para `AFFECTED` porque o aviso ganhou uma correção para a linha), deixa a exceção sem uso, e o check falha até alguém revisar.
- Sem `crate` e `version`, a exceção vale só para o erro do aviso inteiro (`kind: "ERROR"`, aviso sem pacote Rust utilizável). Ela nunca cobre as entradas Rust do mesmo aviso, que continuam sendo avaliadas. Os dois campos vêm juntos ou nenhum.
- `reason` é obrigatório. `review-by` é uma data `AAAA-MM-DD` no máximo 90 dias à frente do dia da execução (decisão do Denilson); data mais distante falha. Depois dela, a exceção vence e o check falha até alguém revisar.
- Exceção que não casa com nenhum achado falha, como o `unused-ignored-advisory` do `deny.toml`. Exceção que casa com mais de um achado também falha, e não aceita nenhum deles. Exceção duplicada, chave desconhecida ou arquivo fora do formato também falham.
- Achado coberto por exceção aparece como aviso no log, com o motivo e a data de revisão.
- Falha da API, resposta curta e erro no próprio arquivo de exceções não têm exceção.

#### Testes

[`tools/repo-advisories/test.sh`](tools/repo-advisories/test.sh) roda o script contra uma API falsa (`python3 -m http.server`) com 49 casos: cada regra acima, as formas recusadas, as exceções e as falhas da API. O job `advisory-tests` do `ci.yml` deste repositório roda os testes em todo PR daqui; ele não existe nos callers.

Para testar contra a API real: `GH_TOKEN=$(gh auth token) tools/repo-advisories/check.sh --lock caminho/Cargo.lock --repo quinn-rs/quinn --min-advisories 13 --exceptions caminho/advisory-exceptions.json quinn quinn-proto quinn-udp`.

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
- Actions fixadas por SHA de commit, com a versão num comentário. Binários (gitleaks, cargo-deny, kubeconform) fixados por versão e conferidos por SHA-256. OpenSpec fixado por lockfile, sem scripts de instalação.
- Roda em pull request, não em push na `main` (que só muda por PR), e uma vez por dia nos callers com `schedule`, só com o job `deny`. Jobs leves, com cache do cargo no `rust`. O `deny` não usa cache: baixa o índice e as crates do `cargo metadata` e o banco da RustSec a cada execução.

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
