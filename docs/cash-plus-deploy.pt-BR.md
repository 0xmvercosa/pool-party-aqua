# Cash+ — plano de deploy com Rabby

Carteira de deploy: **`0x67Fd51e5082205AF0bD97039a6124Ff3368aD0da`**. Rede: **Arbitrum One, chain ID 42161**. Código dos contratos revisado: **`c7bd16c3743400facd8d711cb74c8ebd08efb78b`**, no repositório `0xmvercosa/pool-party-aqua`.

Este documento acompanha o deploy dos contratos depois da conclusão do frontend. Nenhuma transação real foi assinada ou transmitida durante sua preparação. A tela Cash+ de demonstração usa valores simulados; publicar essa tela não publica os contratos.

**Estado desta versão:** o assistente específico Cash+/Rabby está implementado no repositório dos contratos, com revisão independente de seu fluxo de assinatura e recuperação. O deploy público ainda depende dos endereços finais dos papéis, de 1.000 USDC de seed e de ETH para gas. As assinaturas acontecerão na extensão da carteira.

**Verificação concluída em 13/09/2026:** 40 testes da suíte de scripts aprovados, sendo 35 novos para o assistente, typecheck e checagem de artefatos aprovados; ensaio das três etapas concluído em Anvil isolado com estado da Arbitrum. O Solidity não mudou depois dos 91 testes anteriormente registrados. A página e o serviço foram verificados localmente; nenhuma assinatura real da Rabby foi solicitada.

## 1. O que será publicado

O fluxo mínimo tem **três transações assinadas na Rabby**:

| Etapa | Destino | Resultado | Valor nativo da chamada |
| --- | --- | --- | --- |
| 1. Criar a fábrica | Criação de contrato, sem `to` | Publica `CashPlusDeploymentFactory`, sem argumentos de construtor | 0 ETH; há gas |
| 2. Aprovar o seed | Contrato USDC | Autoriza a fábrica a utilizar **exatamente 1.000 USDC** | 0 ETH; há gas |
| 3. Criar e inicializar Cash+ | Endereço verificado da fábrica | Executa `deploy(initCode, usdc, seed, salt)`: cria o vault e seus componentes, transfere o seed e inicializa, atomicamente | 0 ETH; há gas e transferência dos 1.000 USDC aprovados |

O construtor do vault cria seis componentes: Oracle, adaptador Aave USDC, adaptador Aave USD₮0, Pricing, ProgramFactory e Lens. Portanto, a configuração com os dois adaptadores resulta em **oito contratos publicados**, mas não em oito confirmações individuais. Não publique os componentes manualmente. Aqua, SwapVM, Aave, tokens e feeds já existem e serão utilizados nos endereços oficiais.

### Saldo real observado

Uma leitura pública da Arbitrum em **13/09/2026, às 17:33 UTC**, encontrou **0 USDC** e **0,0015005921648 ETH** na carteira informada. Portanto, naquele momento faltavam os 1.000 USDC para o seed. Não foi concluído que esse saldo ETH é suficiente: isso depende da estimativa do assistente/Rabby. Os saldos devem ser consultados novamente antes de executar, pois podem mudar. Esta leitura não efetuou transferência nem assinatura.

### O seed é permanente

Os **1.000 USDC ficam economicamente presos ao vault**: suas cotas são atribuídas a `address(1)` e o contrato impede o resgate dessas cotas. O patrocinador fica com **zero cotas por esse aporte**. Isso é uma defesa da inicialização; não é um investimento pessoal resgatável.

Para ter um investimento resgatável, a carteira deverá fazer um depósito normal separado depois da inicialização. Por exemplo, seed de 1.000 USDC mais investimento de 100 USDC exige 1.100 USDC, além de ETH para gas. O seed participa das mesmas exposições do vault: “permanente” não significa que seu valor esteja garantido.

O ensaio anterior também doou **100 USD₮0** para iniciar o estoque secundário. Essa doação é **opcional** no deploy real e não faz parte das três transações mínimas. Ela não gera cotas para o remetente. Se escolhida, faça-a antes da entrada de investidores e identifique-a separadamente no relatório. É possível construir estoque secundário por conversões autorizadas no sentido USD₮0 → USDC.

## 2. O que foi aproveitado do outro agente

Referência inspecionada: `noria/docs/1inch/deploy-and-test.pt-BR.md`. O comando verdadeiro nesse projeto é **`npm run deploy:aqua`**, registrado em `package.json`; ele executa `scripts/deploy-aqua.ts`.

O padrão útil é uma página local servida em loopback, com descoberta Rabby via EIP-6963, seleção explícita da carteira/rede, preparação sem assinatura, estimativa de gas, revisão persistida, confirmação na extensão e verificação posterior do recibo. O servidor não guarda chave, não assina e não transmite transações. A página também preserva hashes para recuperar operações pendentes, em vez de repetir envios por timeout.

Arquivos de referência:

| Arquivo Noria | Uso na adaptação Cash+ |
| --- | --- |
| `scripts/deploy-aqua.ts` | Servidor local, sessão, controle de origem, revisão, diário e recuperação |
| `scripts/deploy/app.js` | Descoberta Rabby, checagem de conta/rede imediatamente antes de assinar e `eth_sendTransaction` após clique |
| `scripts/lib/aqua-deployment.ts` | Preparação/simulação, nonce, gas e identidade da transação |
| `scripts/lib/aqua-artifacts.ts` | Compilação e identidade dos artefatos |
| `scripts/validate-aqua-deployment.ts` | Ensaio em Anvil próprio, sem transmitir para o RPC público |

Há duas diferenças que impedem copiar o assistente sem adaptação:

1. Noria publica dois contratos por criações externas. Cash+ tem uma criação externa, uma aprovação ERC-20 e uma chamada à fábrica que faz uma criação **interna por CREATE2**. No último recibo, `contractAddress` normalmente é nulo: o endereço do vault deve ser verificado pelo evento `VaultDeployed`, pelo cálculo CREATE2 e pelo código/getters.
2. Noria compara certos runtimes executando o construtor isolado em `eth_call`. Esse procedimento não pode ser copiado diretamente para Cash+: `INITIALIZER` depende do remetente e os componentes criados dependem do endereço do vault. A verificação precisa considerar esse contexto, os `immutableReferences` dos artefatos e todos os valores imutáveis relevantes.

O assistente local de manutenção não é uma API de produto, não precisa entrar na sidebar, não será publicado na hospedagem do frontend e não usa Privy. A Rabby é utilizada para o deploy; a autenticação do investidor continua no fluxo existente da plataforma.

## 3. Configuração que precisa ser conferida antes de assinar

### Carteiras e permissões

| Papel | Quem pode fazer o quê | Definição para o deploy |
| --- | --- | --- |
| Deployer/patrocinador | Cria a fábrica, aprova e fornece o seed | Já informado: `0x67Fd51e5082205AF0bD97039a6124Ff3368aD0da` |
| `governance` | Altera política dentro dos limites fixos, autoriza takers, pode pausar/retomar e operar a estratégia | Endereço a escolher explicitamente na configuração |
| `keeper` | Publica/retira ordens canônicas, movimenta os ativos suportados entre vault/Aave, reduz capacidade e pode pausar | Endereço a escolher explicitamente |
| `guardian` | Pode pausar e ativar emergência | Endereço a escolher explicitamente |
| Taker autorizado | Executa conversões nas regras do contrato | Configurado depois por `setAllowedTaker`; não é argumento do construtor |

Os três papéis são **imutáveis**. Informar a carteira de deploy não define automaticamente os três. É tecnicamente possível usar a mesma carteira em todos, mas isso concentra operação e recuperação e não oferece um keeper automatizado. Se o endereço de um papel estiver errado ou sua chave for perdida, não existe troca administrativa no contrato atual; será necessária migração.

O assistente mostra todos os papéis na revisão e exige que sejam configurados explicitamente. A confirmação final acontece na própria revisão e na Rabby; não é necessário exportar chave privada, seed da carteira, senha ou configurar um signer na hospedagem.

### Endereços dos protocolos

| Campo de `Config` | Valor na Arbitrum |
| --- | --- |
| `usdc` | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |
| `secondary` — USD₮0 | `0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9` |
| `aqua` | `0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a` |
| `router` — SwapVM | `0x111111338c5091E8440b67B168bAe16a668AC0De` |
| `pool` — Aave v3 | `0x794a61358D6845594F94dc1DB02A252b5b4814aD` |
| `usdcAToken` | `0x724dc807b04555b71ed48a6896b6F41593b8C637` |
| `secondaryAToken` | `0x6ab707Aca953eDAeFBc4fD23bA73294241490620` |
| `usdcFeed` | `0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3` |
| `secondaryFeed` — USDT/USD | `0x3f3f5dF88dC9F13eac63DF89EC16ef6e7E25DdE7` |
| `sequencerFeed` | `0xFdB631F5EE196F0ed6FAa767959853A9F217697D` |

O router desta tabela é o usado por Cash+, baseado no SwapVM `32c687c2b73101fc26549e48fa1ff8a4d73afbac`. Não substitua pelo router antigo de Active Reserve apenas porque ele já aparece em outro módulo do produto.

### Parâmetros utilizados nos testes

Os valores abaixo documentam a configuração validada. Eles devem aparecer legíveis na revisão de deploy; não são uma autorização automática para captar até o limite máximo.

| Campo | Valor bruto | Significado |
| --- | --- | --- |
| `hardDepositCap` | `1000000000000` | Limite imutável de 1.000.000 USDC |
| `usdcMaxAge` | `90000` | Feed USDC com idade máxima de 25 horas |
| `secondaryMaxAge` | `90000` | Feed secundário com idade máxima de 25 horas |
| `maxFeedSkew` | `90000` | Diferença máxima de 25 horas entre atualizações |
| `sequencerGrace` | `3600` | Uma hora após recuperação do sequenciador |
| `pegDeviationBps` | `50` | Limite de desvio de 0,50% por feed |
| `depositCap` | `1000000000000` | Capacidade inicial de 1.000.000 USDC; pode ser menor que o teto imutável |
| `minDeposit` | `1000000` | Depósito mínimo de 1 USDC |
| `maxFillBps` | `100` | Uma conversão de até 1% do NAV |
| `dailyBudgetBps` | `2000` | Volume diário de até 20% da base registrada |
| `secondaryTargetBps` | `1000` | Alvo de 10% no ativo secundário |
| `secondaryCapBps` | `2000` | Limite de 20% para conversões que aumentam a exposição secundária |
| `baseSpreadBps` | `5` | Spread base de 0,05% |
| `maxSurchargeBps` | `10` | Acréscimo máximo de 0,10%, conforme estoque |
| `hotUsdcBps` | `500` | Alvo de 5% de USDC fora da Aave |
| `hotSecondaryBps` | `0` | Estoque secundário pode ficar inteiramente na Aave |

As taxas administrativas e de performance do contrato são **zero**. A taxa comercial do simulador econômico não é cobrada onchain. O spread é receita da conversão, não uma promessa de rendimento anual.

`Config` possui 19 campos e `Policy` 10, na ordem declarada em `CashPlusTypes.sol`. A ABI gerada deve fazer a codificação; não montar manualmente uma sequência de endereços sem os nomes dos campos. USDC e USD₮0 usam seis casas decimais; o seed `1000` deve ser codificado como `1000000000`.

A base diária não cresce a cada depósito. Com o seed de 1.000 USDC, o limite diário inicial da política de 20% começa em 200 USDC; novos depósitos no mesmo dia não reinicializam o orçamento. Isso é intencional para impedir que o limite seja contornado.

## 4. Comandos existentes: preparar o ambiente e conferir artefatos

Os caminhos abaixo são os desta máquina. Os comandos de leitura não assinam transações. `forge build` recompila artefatos locais; `cash-plus:export` regenera ABIs no frontend.

```sh
export PATH="$HOME/.foundry/bin:$PATH"
export CASH_PLUS_FRONTEND_ROOT='/Users/murilovercosa/Documents/Codex/2026-09-13/an/work/cash-plus-frontend'
export CASH_PLUS_CONTRACTS_ROOT='/Users/murilovercosa/Documents/Codex/2026-09-13/an/work/cash-plus-contracts/contracts'
export CASH_PLUS_RPC_URL='https://arb1.arbitrum.io/rpc'
export CASH_PLUS_DEPLOYER='0x67Fd51e5082205AF0bD97039a6124Ff3368aD0da'

node --version
pnpm --version
forge --version
cast --version
anvil --version

git -C "$CASH_PLUS_CONTRACTS_ROOT/.." status --short
git -C "$CASH_PLUS_CONTRACTS_ROOT/.." rev-parse HEAD
git -C "$CASH_PLUS_FRONTEND_ROOT" status --short
```

O ambiente verificado utilizou Node 22, pnpm 11.5.0 e Foundry 1.0.0. A identidade dos contratos é determinada pelo fonte, compilador e configurações abaixo; o assistente confere a compilação ao iniciar.

```sh
cd "$CASH_PLUS_CONTRACTS_ROOT"
FOUNDRY_PROFILE=cashplus forge build --sizes
```

Configuração obrigatória: Solidity **0.8.28+commit.7893614a**, EVM **Cancun**, otimização **200 runs**, **viaIR=true**. Não usar o profile padrão do Active Reserve, que tem outro número de runs.

Tamanhos registrados na revisão:

| Item | Bytes | Limite |
| --- | ---: | ---: |
| Runtime do vault | 24.486 | 24.576 |
| Creation bytecode do vault | 47.681 | — |
| Argumentos dos dois structs | 928 | — |
| Initcode completo | 48.609 | 49.152 |

Sobram apenas **90 bytes de runtime** e **543 bytes de initcode**. Uma mudança de código exige nova conferência e pode impedir o deploy. Não ignorar erro de tamanho nem alterar o compilador para contorná-lo.

Para regenerar e conferir ABIs, quando houver alteração de artefatos:

```sh
cd "$CASH_PLUS_FRONTEND_ROOT"
pnpm cash-plus:export
git diff -- src/lib/cash-plus/abi
pnpm typecheck
```

O commit Solidity citado permanece inalterado e já teve **91 testes aprovados**, incluindo quatro testes Cash+ contra Aqua/SwapVM/Aave oficiais em fork. Não foram repetidos apenas para produzir este documento. A implementação do assistente acrescenta sua própria necessidade de testes de assinatura, recuperação e ensaio da sequência exata de deploy.

### Leituras públicas opcionais da rede e da carteira

```sh
cast chain-id --rpc-url "$CASH_PLUS_RPC_URL"
cast balance "$CASH_PLUS_DEPLOYER" --ether --rpc-url "$CASH_PLUS_RPC_URL"
cast call 0xaf88d065e77c8cC2239327C5EDb3A432268e5831 \
  'balanceOf(address)(uint256)' "$CASH_PLUS_DEPLOYER" \
  --rpc-url "$CASH_PLUS_RPC_URL"
cast call 0x111111338c5091E8440b67B168bAe16a668AC0De \
  'AQUA()(address)' --rpc-url "$CASH_PLUS_RPC_URL"
```

O chain ID deve ser 42161. O saldo USDC deve ser interpretado em seis casas; 1.000 USDC são `1000000000`. Gas é pago em ETH **na Arbitrum**. Não há um custo fixo garantido: a revisão de cada transação e a Rabby devem apresentar a estimativa atual.

## 5. Comportamento implementado no assistente Cash+/Rabby

O assistente está no repositório dos contratos, em arquivos `scripts/cash-plus-deploy*`, separado do frontend e do operador de forks existente. A revisão inspecionou o serviço, a página, a persistência e o ensaio.

1. **Configuração persistida:** carteira, chain ID, papéis, parâmetros, artefatos/hashes, salt, seed, etapa e revisão. Um journal já utilizado é vinculado ao build e aos papéis originais. Mudá-los exige resolver esse contexto; o assistente não continua silenciosamente com outra configuração.
2. **Identidade e simulação:** confere rede, atualidade do bloco RPC, runtimes Aqua/SwapVM, relação router→Aqua, tokens/reservas Aave, descrições e saúde dos feeds, peg e sequenciador. Simula cada chamada com o remetente e destino reais. Confere saldo ETH e saldo/allowance USDC e estima a criação completa com os seis componentes.
3. **Revisão antes de assinatura:** mostra destino, função, seed permanente, papéis, capacidade, salt, endereço CREATE2 previsto, nonce, valor nativo zero e gas. A aprovação mostra o spender e o valor exato. A página compara novamente a revisão retornada pelo servidor com a revisão que foi exibida antes de enviar à Rabby.
4. **Rabby no navegador:** usa EIP-6963 com identificação Rabby, conta exata e chain `0xa4b1`. Revalida `eth_accounts` e `eth_chainId` imediatamente antes do envio. Somente o clique de confirmação aciona `eth_sendTransaction` no provider da extensão.
5. **Recuperação:** grava intenção de assinatura antes de abrir a extensão, salva o hash e verifica transação/recibo. Timeout não significa falha e não autoriza reenvio. Após reinício, resolve a operação existente antes de avançar. Uma substituição precisa corresponder ao remetente, nonce, destino, valor e calldata originais.
6. **Verificação por etapa:** verifica a criação externa da fábrica, a aprovação ERC-20 exata e a chamada à fábrica com evento CREATE2 e seed. Um recibo bem-sucedido de outra operação não libera a etapa seguinte.
7. **Publicação verificável:** gera relatório, argumentos dos construtores e Standard JSON Input. Exporta o manifesto live após a verificação de runtime e inicialização. Se a gravação do arquivo falhar, a operação permanece pendente para repetir somente a verificação, sem repetir a transação.
8. **Isolamento:** escuta apenas em loopback, recusa origem/Host inesperados, usa sessão local, limita o corpo dos requests e impede operações simultâneas. O servidor não tem chave, signer nem função de broadcast e não integra o bundle do investidor.

### Checagens específicas após a criação interna

O `salt` efetivo é `keccak256(abi.encode(deployer, salt))`. O `predict(deployer, salt, keccak256(initCode))` da fábrica deve produzir o mesmo vault registrado em `VaultDeployed`. Nunca envie USDC antecipadamente para o endereço previsto: prefunding do vault ou de componentes pode fazer o construtor rejeitar o deploy. Nesse caso, preserve o registro, selecione outro salt e prepare novamente.

Na configuração com os dois adaptadores, os filhos seguem a ordem de criação do construtor: Oracle, adaptador USDC, adaptador secundário, Pricing, ProgramFactory e Lens. A verificação deve ligar os endereços a essa ordem e conferir:

- Vault: `INITIALIZER=factory`, protocolos/tokens, papéis e hard cap da revisão; `initialized=true`, versão 1 e política exata.
- Seed: `Seeded` registra 1.000 USDC; `sharesOf(address(1))=1000000000000000000000`, `totalShares` igual na inicialização; o sponsor não recebeu cotas. Imediatamente depois, antes de outras operações, o vault contém os 1.000 USDC. Leituras no bloco do recibo também enxergam operações posteriores no mesmo bloco; o relatório distingue isso com `bootstrapStateMatches`, em vez de confundir uma doação posterior com falha na criação.
- Adaptadores: `VAULT`, `UNDERLYING`, `POOL`, `A_TOKEN`, além de `UNDERLYING_ASSET_ADDRESS`/`POOL` nos recibos Aave.
- Oracle: feeds, escalas, casas decimais, idades, skew, grace e limite de peg; leitura válida de preços.
- Pricing: vault/router; ProgramFactory: vault/pricing; Lens: vault.
- Allowance do patrocinador para fábrica consumida até zero na aprovação exata; allowance dos dois tokens do vault para Aqua igual a zero fora de uma conversão.
- Recibo incluído no bloco canônico observado e código de todos os componentes coerente com os artefatos/configuração. Isso ainda não é uma garantia de finalização na Ethereum.

Se `bootstrapStateMatches=false`, o deploy pode estar verificado pelos eventos e pelo código, mas o manifesto live fica retido. Inspecione as operações do mesmo bloco antes de ativar depósitos. Não repita o deploy para tentar obter um arquivo ausente.

## 6. Comandos do assistente Cash+/Rabby e fluxo na página

Os comandos foram conferidos no `package.json` do repositório dos contratos. `deploy:cash-plus:check` compila/codifica offline; `deploy:cash-plus:rehearse` usa um Anvil próprio e saldo artificial. `deploy:cash-plus`, apresentado depois dos checks, inicia a página local sem enviar transações.

```sh
cd "$CASH_PLUS_CONTRACTS_ROOT/.."
pnpm install --frozen-lockfile
pnpm deploy:cash-plus:check
pnpm typecheck
pnpm test
pnpm deploy:cash-plus:rehearse
```

O ensaio específico do assistente utiliza **chain ID 42161 dentro de um Anvil isolado**, para exercitar as mesmas verificações de transação do serviço live. Ele verifica processo, metadata, instance ID e hash do bloco de origem antes dos writes. O relatório fica em `.runtime/cash-plus-deployment-rehearsal.json`. Isso é diferente do CLI de demonstração do frontend, que exige chain ID 31337. Nenhum hash de qualquer desses ensaios é uma transação pública da Arbitrum.

### Evidência da rodada final

| Verificação | Resultado |
| --- | --- |
| Typecheck dos scripts do assistente | Aprovado |
| Suíte de scripts, incluindo assistente e `app.js` com provider simulado | **40 aprovados: 5 existentes e 35 novos** — 27 de deploy e 8 de navegador, incluindo recuperação, rejeição explícita, revisão alterada, troca de conta/rede e recibo incompatível |
| Compilação/encoding offline | Aprovados; runtime 24.486 bytes e initcode 48.609 bytes |
| Sequência em Anvil | **3/3 etapas aprovadas**: fábrica, aprovação exata, deploy/inicialização |
| Identidade do vault e seis filhos | Runtime completo e imutáveis conferidos; `bootstrapStateMatches=true` |
| Servidor local | Restrições de Host/origin/sessão e bloqueio de manifesto prematuro conferidos |
| Fonte para explorer | Sete arquivos Standard JSON válidos; os dois adaptadores compartilham o mesmo fonte |
| Manifesto | Formato aceito pelo `parseCashPlusDeployment` real do frontend; o manifesto do ensaio não foi instalado como live |
| Verificação de segredos do assistente | Histórico e working tree aprovados, sem achados nos 15 arquivos verificados |

O ensaio final usou o bloco de origem **504813926**, hash **`0xb1c615b0403083840e5dac1e092d035e1422f268537850093e7edc6f3cd67485`**; a última etapa foi verificada às **18:02:03 UTC**. Consumo observado no fork: fábrica **369.872 gas**, aprovação **55.437 gas**, criação/inicialização **10.389.497 gas**. Esses números não são uma cotação de custo em ETH da rede pública: custos L2/L1 e estimativas devem ser consultados no momento de cada assinatura.

O serviço de identidade, feeds e recibos do ensaio é o código final. Depois dele, apenas a ordem de gravação do manifesto, os exports dos filhos e fixtures de teste foram ajustados; esses caminhos receberam checks locais próprios. Uma operação real ainda depende do provider Rabby instalado, da rede disponível e das três confirmações do usuário.

Escolha os três endereços públicos dos papéis e substitua os marcadores abaixo. Eles são entradas de configuração, não chaves privadas. O comando recusa marcadores inválidos ou papéis ausentes. Se decidir utilizar a mesma carteira em todos os papéis, preencha explicitamente o endereço informado em cada variável, ciente de que o contrato não permite rotação futura.

```sh
export CASH_PLUS_GOVERNANCE='COLE_ENDERECO_PUBLICO_DA_GOVERNANCE'
export CASH_PLUS_KEEPER='COLE_ENDERECO_PUBLICO_DO_KEEPER'
export CASH_PLUS_GUARDIAN='COLE_ENDERECO_PUBLICO_DO_GUARDIAN'
export CASH_PLUS_RPC_URL='https://arb1.arbitrum.io/rpc'

pnpm deploy:cash-plus
```

Abrir [http://127.0.0.1:3211](http://127.0.0.1:3211) no Chrome/Brave com a Rabby instalada. A porta é diferente da referência Noria, que usa 3210. Manter o terminal aberto. `Ctrl+C` encerra apenas esse servidor; se houver conflito de porta, localizar a instância já iniciada em vez de encerrar processos desconhecidos.

Na página:

1. Conferir que a URL é a de loopback acima e que a carteira indicada está correta.
2. Selecionar a carteira informada e Arbitrum One. Conexão não envia fundos.
3. Conferir os três papéis, os parâmetros e a indicação de seed permanente. Preparar a fábrica, revisar e confirmar a criação na Rabby. Esperar o recibo verificado.
4. Preparar a aprovação de **1.000 USDC para a fábrica verificada**. Conferir spender/valor na página e na Rabby; assinar e verificar.
5. Preparar a chamada `deploy` com o initcode completo e salt. Conferir endereço previsto, papéis, parâmetros e seed. Assinar a chamada à fábrica e verificar o evento e os oito contratos.
6. Baixar o relatório e guardar os argumentos, fontes para explorer, hashes e manifesto. Publicar o fonte no explorer e só então configurar a UI live.

Não realizar outra transação com a mesma carteira enquanto uma revisão de nonce estiver sendo assinada. Se o nonce mudar antes do envio, cancelar a revisão ainda não iniciada e preparar novamente; se já houver hash, recuperar o recibo.

O assistente verifica a existência dos 1.000 USDC **já na preparação da primeira etapa**, portanto o saldo zero observado impede começar o deploy real, mesmo que a criação da fábrica por si só não transfira USDC. Isso evita gastar gas no início de um fluxo sem o capital obrigatório.

Um timeout, mudança de conta/rede ou fechamento da página após o início da assinatura pode deixar a operação bloqueada até recuperar o hash na Activity da Rabby. Somente uma rejeição explícita da extensão e uma verificação de nonce permitem liberar esse caminho automaticamente. Não apagar `.runtime` para contornar uma operação incerta.

## 7. Leituras e verificação de fonte depois do deploy

Os valores `COLE_ENDERECO_...` abaixo são marcadores explícitos. Substituí-los pelos endereços **reais do relatório** antes de copiar os comandos. Esses comandos são leituras e não transmitem transações.

```sh
export CASH_PLUS_FACTORY='COLE_ENDERECO_REAL_DA_FABRICA'
export CASH_PLUS_VAULT='COLE_ENDERECO_REAL_DO_VAULT'

cast call "$CASH_PLUS_VAULT" 'INITIALIZER()(address)' --rpc-url "$CASH_PLUS_RPC_URL"
cast call "$CASH_PLUS_VAULT" 'initialized()(bool)' --rpc-url "$CASH_PLUS_RPC_URL"
cast call "$CASH_PLUS_VAULT" 'GOVERNANCE()(address)' --rpc-url "$CASH_PLUS_RPC_URL"
cast call "$CASH_PLUS_VAULT" 'KEEPER()(address)' --rpc-url "$CASH_PLUS_RPC_URL"
cast call "$CASH_PLUS_VAULT" 'GUARDIAN()(address)' --rpc-url "$CASH_PLUS_RPC_URL"
cast call "$CASH_PLUS_VAULT" 'totalShares()(uint256)' --rpc-url "$CASH_PLUS_RPC_URL"
cast call "$CASH_PLUS_VAULT" 'sharesOf(address)(uint256)' \
  0x0000000000000000000000000000000000000001 --rpc-url "$CASH_PLUS_RPC_URL"
cast call "$CASH_PLUS_VAULT" 'totalAssets()(uint256)' --rpc-url "$CASH_PLUS_RPC_URL"
cast call "$CASH_PLUS_VAULT" 'activeStrategies()(bytes32[])' --rpc-url "$CASH_PLUS_RPC_URL"
cast call 0xaf88d065e77c8cC2239327C5EDb3A432268e5831 \
  'allowance(address,address)(uint256)' "$CASH_PLUS_VAULT" \
  0x1111113CCf1426A8E30e2bfF5E005d929bF6a90a --rpc-url "$CASH_PLUS_RPC_URL"
```

O assistente já escreve os arquivos abaixo em **`.runtime/cash-plus-deployment/`**, dentro do repositório dos contratos. Os argumentos dos seis filhos e o manifesto são escritos depois da verificação bem-sucedida do vault e do estado inicial. Os arquivos de fonte são gerados ao iniciar o servidor.

| Contrato | Standard JSON Input | Argumentos ABI |
| --- | --- | --- |
| Fábrica externa | `factory-standard-input.json` | `factory-constructor-args.hex` — vazio (`0x`) |
| Vault | `vault-standard-input.json` | `vault-constructor-args.hex` |
| Oracle | `oracle-standard-input.json` | `oracle-constructor-args.hex` |
| Adaptador USDC | `adapter-standard-input.json` | `usdc-adapter-constructor-args.hex` |
| Adaptador USD₮0 | `adapter-standard-input.json` | `secondary-adapter-constructor-args.hex` |
| Pricing | `pricing-standard-input.json` | `pricing-constructor-args.hex` |
| ProgramFactory | `program-factory-standard-input.json` | `program-factory-constructor-args.hex` |
| Lens | `lens-standard-input.json` | `lens-constructor-args.hex` |

Também são produzidos `configuration.json`, `deployment.json`, os arquivos `factory-unsigned.json`, `approval-unsigned.json` e `vault-unsigned.json` conforme cada etapa é preparada, e `deployment.live.json` ao concluir. Preserve a pasta inteira como evidência do deploy. O journal contém endereços, dados de transação e recibos; não contém chave de carteira nem RPC com credencial.

Para abrir essa pasta no Finder desta máquina:

```sh
export CASH_PLUS_DEPLOY_OUTPUT="$CASH_PLUS_CONTRACTS_ROOT/../.runtime/cash-plus-deployment"
open "$CASH_PLUS_DEPLOY_OUTPUT"
```

Se precisar regenerar as entradas Standard JSON da fábrica e do vault sem chave de API e sem broadcast:

```sh
cd "$CASH_PLUS_CONTRACTS_ROOT"
mkdir -p ../.runtime/cash-plus-source-verification

FOUNDRY_PROFILE=cashplus forge verify-contract "$CASH_PLUS_FACTORY" \
  src/cashplus/CashPlusDeploymentFactory.sol:CashPlusDeploymentFactory \
  --show-standard-json-input \
  > ../.runtime/cash-plus-source-verification/factory-standard-input.json

FOUNDRY_PROFILE=cashplus forge verify-contract "$CASH_PLUS_VAULT" \
  src/cashplus/CashPlusVault.sol:CashPlusVault \
  --show-standard-json-input \
  > ../.runtime/cash-plus-source-verification/vault-standard-input.json
```

No [Arbiscan](https://arbiscan.io): **Contract → Verify and Publish → Solidity (Standard-Json-Input)**, compilador **v0.8.28+commit.7893614a**, licença MIT. Use o endereço real do relatório, o Standard JSON correspondente e os argumentos ABI exatos da tabela. Se o formulário pedir hex sem prefixo, remova apenas `0x`, preservando todo o conteúdo. A fábrica externa não tem argumentos; o vault recebe `Config` e `Policy`. Repita para os seis componentes com seus argumentos próprios. A checagem local de runtime e a publicação de fonte no explorer são verificações diferentes.

A assinatura do deploy permanece inteiramente na Rabby. Não é necessário usar `forge create`, `cast send`, `--private-key` ou uma chave de API do explorer para o caminho descrito neste documento. Os comandos Standard JSON apenas geram os arquivos para verificação manual pelo navegador.

## 8. Ativação da estratégia e do frontend live

Publicar os contratos não configura fluxo comercial nem executa conversões sozinho. A sequência operacional, com chamadas assinadas pelos papéis corretos, será:

1. Governance autoriza os takers selecionados por `setAllowedTaker`.
2. Se escolhida, a doação secundária é feita e registrada separadamente antes dos investidores.
3. Keeper/governance faz `park` dos ativos elegíveis, respeitando os buffers.
4. Keeper/governance publica uma ordem com `shipCanonical`. O programa e o hash devem coincidir com ProgramFactory e SwapVM. A ordem dura no máximo **300 segundos**; até oito podem estar ativas.
5. O taker autorizado obtém uma cotação e executa a conversão com input-first, exact-input, mínimo de saída e deadline. Tokens realmente mudam de endereço nessa etapa.
6. Verificar `ConversionSettled`, transferências ERC-20, retirada Aave quando necessária, orçamento consumido e allowance Aqua novamente zero.
7. Testar investimento/resgate normal do próprio investidor e manter disponível a saída proporcional.

**Automação live ainda precisa de um caminho de assinatura operacional.** O keeper local atual usa contas desbloqueadas do Anvil e é restrito a forks. Não pode ser transformado em keeper mainnet trocando a URL, nem a Rabby pode ser tratada como uma chave de assinatura automática sem interação. O contrato suporta o papel keeper; um operador live com um signer autorizado ainda precisa ser definido e implementado antes de prometer execução contínua. O deploy pode existir sem ordens ativas, mas nesse estado não há receita de conversão.

O manifesto de frontend deve ser gerado a partir do deploy real, com `mode: live`, `chainId: 42161`, RPC HTTPS público apropriado, bloco/hash de deploy, endereços e code hashes verificados. O schema fica em `src/lib/cash-plus/config/deployments.ts`; o arquivo consumido pelo frontend é `src/lib/cash-plus/config/deployment.generated.json`.

Após concluir as três transações reais e revisar `deployment.json`, o comando abaixo valida o arquivo exportado, guarda uma cópia do manifesto anterior e instala o manifesto real. Não utilize o relatório `.runtime/cash-plus-deployment-rehearsal.json` como entrada.

```sh
export CASH_PLUS_LIVE_MANIFEST="$CASH_PLUS_CONTRACTS_ROOT/../.runtime/cash-plus-deployment/deployment.live.json"
cd "$CASH_PLUS_FRONTEND_ROOT"

pnpm exec tsx --eval '
import { readFileSync, copyFileSync, mkdirSync } from "node:fs";
import { parseCashPlusDeployment } from "./src/lib/cash-plus/config/deployments.ts";
const source = process.env.CASH_PLUS_LIVE_MANIFEST;
if (!source) throw new Error("CASH_PLUS_LIVE_MANIFEST missing");
const deployment = parseCashPlusDeployment(JSON.parse(readFileSync(source, "utf8")));
if (deployment.mode !== "live" || deployment.chainId !== 42161) throw new Error("Expected verified Arbitrum live manifest");
const target = "src/lib/cash-plus/config/deployment.generated.json";
const directory = ".runtime/cash-plus-deployment-backups";
mkdirSync(directory, { recursive: true });
const backup = directory + "/deployment-before-live-" + Date.now() + ".json";
copyFileSync(target, backup);
copyFileSync(source, target);
console.log("Installed", deployment.vault, "Previous manifest:", backup);
'

git diff -- src/lib/cash-plus/config/deployment.generated.json
```

A validação desse formato não prova, sozinha, que o deploy é público: essa prova vem do recibo real e da verificação do assistente. Nunca renomeie ou altere um manifesto de fork para fazê-lo passar por live.

Na configuração de build live:

```text
NEXT_PUBLIC_FEATURE_CASH_PLUS=true
NEXT_PUBLIC_CASH_PLUS_MODE=live
NEXT_PUBLIC_MOCK_MODE=false
```

Manter o Privy/wagmi existente do produto e suas configurações reais. Uma URL que vai para `NEXT_PUBLIC_*`/manifesto de cliente é pública; não inserir uma credencial secreta de RPC. O schema atual também recusa usuário/senha, query string e fragmento no RPC. Usar o manifesto e as variáveis corretas no build; mudar só o arquivo `.env` depois não altera um bundle já publicado.

Após instalar o manifesto real e revisar o diff:

```sh
cd "$CASH_PLUS_FRONTEND_ROOT"
pnpm typecheck
pnpm i18n:check
pnpm build
pnpm secrets:check
```

Executar esses checks após a integração final, sem repeti-los em loop quando nada mudou. O seed/donations não devem aparecer como rendimento da conta do investidor. Não copiar o manifesto do fork para produção.

## 9. Comandos de fork que já existem — apenas ensaio

Os comandos abaixo estão registrados hoje no frontend. Eles usam Anvil local, chain ID **31337**, e não são comandos Rabby/mainnet:

```sh
cd "$CASH_PLUS_FRONTEND_ROOT"
pnpm cash-plus:demo --step start
pnpm cash-plus:verify
pnpm cash-plus:demo --step invest --amount 1000
pnpm cash-plus:keeper --once
pnpm cash-plus:counterparty --scenario normal --amount 10
pnpm cash-plus:counterparty --scenario exceeds-limit
pnpm cash-plus:demo --step withdraw
pnpm cash-plus:evidence
```

`start` cria um novo fork, arquiva o estado anterior, publica os contratos locais e atualiza o manifesto de demonstração. Não executar essa sequência sobre a cópia preparada com um manifesto live sem preservar/separar o contexto. O RPC público pode deixar de servir estado histórico em minutos; nesse caso é necessário novo fork ou RPC de arquivo. Os recibos antigos continuam válidos como evidência do ensaio, mas não provam disponibilidade atual para novas operações.

## 10. Pausa, recuperação e limites conhecidos

O achado **CP-L01**, de severidade baixa, permanece documentado: uma pausa parcial pode consultar e falhar no oracle quando ele está stale. O código atual permite **`setPause(true, true)`** para pausar os dois fluxos sem ler os preços. Essa deve ser a instrução operacional durante incidente de oracle, enquanto o achado não for corrigido e testado.

Governance ou guardian pode ativar `setEmergencyMode(true)`. Nesse modo, o investidor pode solicitar a sua parte proporcional sem valuation pelo oracle; pode receber USDC, USD₮0 e aTokens. Isso evita depender da retirada da Aave, mas não contorna bloqueios de transferência dos tokens, pausas da Aave ou restrições de emissores. A ativação de emergência também depende de os tokens aceitarem revogar allowances.

Retirar a emergência e despausar exigem governance e preços válidos. Não existe upgrade nem retirada administrativa dos fundos dos investidores. Para migrar, os próprios investidores precisam sair da posição antiga e entrar na nova. Uma falha de retirada deve preservar as cotas; não reenviar automaticamente uma transação cujo resultado é desconhecido.

## 11. Pendências objetivas antes da execução real

| Item | Estado / condição para concluir |
| --- | --- |
| Código Solidity | Commit revisado inalterado; 91 testes anteriores aprovados. CP-L01 tem workaround operacional documentado |
| Assistente Rabby Cash+ | Implementado e revisado; suíte de 40 testes aprovada, sendo 35 novos do assistente, checks locais aprovados e ensaio das três etapas concluído. Assinaturas públicas ainda não realizadas |
| Carteira de deploy | Informada e incorporada ao plano |
| Governance/keeper/guardian | Endereços finais precisam estar explícitos na configuração/revisão, pois não podem ser trocados depois |
| Seed | Saldo consultado em 13/09/2026 às 17:33 UTC: **0 USDC**. Faltavam os 1.000 USDC permanentes; conferir novamente antes de executar. Não inferir autorização financeira a partir do saldo fictício da UI |
| Protocolos/feeds atuais | O preflight precisa ler identidades e saúde no momento do deploy; USDT/USD usado para USD₮0 carrega uma hipótese de mercado/bridge |
| Live manifesto + explorer | Produzidos a partir dos recibos reais e dos artefatos exatos; ainda não existem endereços reais Cash+ neste plano |
| Operação automatizada | Keeper/taker live e seus caminhos de assinatura são trabalho separado do deploy; a implementação atual de CLI é fork-only |

Referência: [relatório histórico da revisão Solidity](cash-plus-final-contract-review.md), preservado com o escopo e os limites originais. O código verificado está em [contracts/src/cashplus](https://github.com/0xmvercosa/pool-party-aqua/tree/c7bd16c3743400facd8d711cb74c8ebd08efb78b/contracts/src/cashplus). A revisão limitada não identificou exploit crítico ou alto nos caminhos examinados; CP-L01 permanece aberto, com workaround. Isso não constitui auditoria externa, prova formal nem garantia de principal/rentabilidade.
