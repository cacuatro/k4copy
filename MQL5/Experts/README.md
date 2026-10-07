# K4 Rejection Cycles (XAUUSD / MetaTrader 5)

Robô (Expert Advisor) que opera **ciclos de entradas** no **XAUUSD** na **recusa de topos/fundos relevantes**, pensado para **conta cent**. A conta precisa ser **hedge**.

## Como funciona

1. **Topo/fundo relevante** (padrão M30): o robô usa o topo e o fundo **mais recentes** que atendem a todas estas condições:
   - é a máxima (ou mínima) mais extrema dos **12 candles anteriores**;
   - tem pelo menos **3 candles depois** confirmando;
   - **nenhum candle depois dele o superou**;
   - o movimento até ele, ou a partir dele, tem pelo menos 1,5×ATR.

   Em tendência de alta, o fundo acompanha os **fundos mais altos** dos recuos. Em tendência de baixa, o topo acompanha os **topos mais baixos**. Os dois aparecem como linhas tracejadas (topo em vermelho, fundo em azul).

2. **Recusa** (padrão M5): é um candle fechado que atende a todas estas condições:
   - toca a zona do nível;
   - não rompe o nível mais que 0,5×ATR;
   - fecha de volta do lado certo;
   - tem cor a favor;
   - tem pavio de pelo menos 40% do tamanho do candle.

   Recusa no topo abre **VENDA**. Recusa no fundo abre **COMPRA**.

3. **Ciclo**: cada topo/fundo relevante abre **um ciclo**, com até **`InpEntriesPerCycle` entradas** (padrão 10). A 1ª recusa no nível abre `InpOrdersPerRejection` ordem(ns), com padrão de 1. As próximas entradas dependem de `InpEntryMode`:
   - `Uma por recusa no nível` (padrão): **cada novo candle de recusa** naquele nível abre mais ordem(ns).
   - `Pirâmide`: uma nova ordem a cada `InpStepPrice` US$ que o preço andar **a favor** desde a última entrada (com pelo menos `InpMinSecondsBetween` segundos entre ordens).
   - `Preço médio`: uma nova ordem a cada `InpStepPrice` US$ **contra** desde a última entrada.

   Na pirâmide, o preço médio sobe junto com as entradas. Por isso o alvo "US$ a favor do preço médio" também se afasta. Para pirâmide, prefira o alvo em **% topo-fundo** (um preço fixo) ou o **trailing stop**.
   - O ciclo **termina quando a cesta dele fecha**, por alvo, trailing ou stop, **mesmo antes de completar as N entradas**. Aquele topo/fundo não é operado de novo.
   - Quando o preço **sai do nível** (por exemplo, rompe o topo/fundo) e chega ao **próximo topo/fundo relevante**, a recusa ali **inicia um novo ciclo**, mesmo que o anterior não tenha completado as N entradas. O ciclo anterior **para de abrir ordens**, mas as ordens dele continuam até o alvo, o trailing ou o stop. Cada ciclo tem a própria cesta, o próprio limite de entradas e o próprio alvo/trailing. Esse é o padrão (`InpNewCycleAfterLimit = false`).
   - Com `InpNewCycleAfterLimit = true`, o robô **espera** o ciclo atual completar as N entradas (ou fechar) antes de começar outro.
   - Um ciclo também deixa de abrir ordens quando o trailing dele ativa. Isso libera o próximo ciclo.
   - Um "novo topo" criado só por um pavio que passou um pouco do nível de um ciclo aberto é tratado como **o mesmo nível**.
   - Os ciclos são numerados (#1, #2, ...). O número aparece no painel, no Diário, nas linhas do gráfico e no comentário das ordens.
   - `InpMaxOpenCycles` limita quantos ciclos podem ficar abertos ao mesmo tempo (padrão 3, máximo 10).
   - `InpMaxCycles` faz o robô parar depois de X **ciclos iniciados**. A contagem pode ser **por dia** (zera todo dia) ou **total** (zera com `InpResetState = true`). Os ciclos já abertos terminam normalmente.

4. **Saída** (para cada ciclo): a cesta fecha inteira no alvo escolhido em `InpTPMode`:
   - `Valor em dinheiro (X)`: quando o lucro **líquido** somado (já descontando comissão e swap) chega a `InpBasketTPMoney` (+ `InpTPPerExtraOrder` por ordem extra).
   - `% da distância topo-fundo`: o alvo é um preço. A partir do nível operado, o preço precisa andar `InpTPRangePct`% da distância entre o topo e o fundo relevantes, ou seja, as linhas tracejadas no início do ciclo. Exemplo: topo 4.402 e fundo 4.304 (distância US$ 98). Com 30%, o alvo de venda fica em 4.372,60. Com 200%, fica em 4.206.
   - `Dinheiro ou % topo-fundo`: o que vier primeiro.
   - `US$ a favor do preço médio` (**padrão**): o alvo é o preço médio da cesta mais `InpTPPriceDist` (ex.: US$ 3). Não depende da moeda da conta nem do lote.

   O alvo de cada ciclo aparece como **linha verde pontilhada**. Com `InpServerTP = true`:
   - o alvo vai como **TP real** em todas as ordens do ciclo, nunca antes do zero a zero líquido;
   - o **stop técnico** vai como **SL real**;
   - assim a cesta sai no preço exato mesmo com o MT5 fechado.

5. **Trailing stop da cesta** (`InpTrailMode`):
   - `Ao atingir o alvo, deixa correr`: em vez de fechar no alvo, o robô passa a seguir o preço.
   - `A partir de X US$ a favor do preço médio`: o trailing liga quando o preço anda `InpTrailStartPrice` a favor do zero a zero, ou ao atingir o alvo, o que vier primeiro.

   Com o trailing ligado, o alvo **não fecha** a cesta: ele só ativa o trailing, e não vai TP real para a corretora. Depois que o trailing liga:
   - o SL real das ordens passa a acompanhar o trailing;
   - a cesta sai quando o preço devolver `InpTrailDistPrice` do melhor ponto;
   - o stop **garante `InpTrailLockPct`% (padrão 50%) do lucro do momento da ativação** e nunca fica pior que o zero a zero líquido;
   - o stop aparece como linha laranja, e o ciclo não abre novas ordens.
   - Recomendação: use um recuo (`InpTrailDistPrice`) menor que a distância do alvo.

6. **Outras saídas**:
   - **Stop técnico:** o preço passa 1×ATR além do nível. A cesta fecha e o ciclo termina.
   - **Stop em dinheiro da cesta:** `InpBasketSLMoney`.
   - **Saída por tempo:** `InpTimeExitMinutes`, **desligada por padrão**.
   - **Proteções da conta:** meta diária, perda diária e equity alvo. Elas fecham todos os ciclos.

## Painel e Diário

No gráfico, cada linha tem nome. Passe o mouse para ver o nome, ou ative "Mostrar descrições dos objetos" nas propriedades do gráfico. As linhas são:
- topo e fundo relevantes, tracejados. Ficam **cinza** quando o nível já foi operado;
- nível do ciclo, em dourado;
- alvo, verde pontilhado;
- trailing, laranja;
- stop técnico, vermelho pontilhado.

O painel mostra cada ciclo aberto com:
- direção, nível e entradas feitas/limite;
- posições, preço médio, lucro líquido e alvo;
- trailing, quando estiver ativo.

O painel também mostra quantas cestas saíram por cada motivo e **quanto vale US$ 1 de movimento do ouro na sua conta**.

Cada fim de ciclo aparece na aba **Diário**, com o motivo e o **resultado líquido** do ciclo. O relatório do Testador mostra uma linha por ordem; o resultado da cesta inteira está no Diário.

## Instalação

1. No MT5: **Arquivo → Abrir pasta de dados**.
2. Copie `K4_RejectionCycles.mq5` para `MQL5/Experts/`.
3. Abra no MetaEditor e compile (F7).
4. Arraste o robô para um gráfico do XAUUSD (qualquer timeframe) e ative o **Algo Trading**.

## Parâmetros principais

| Parâmetro | Padrão | Significado |
|---|---|---|
| `InpSwingTF` | M30 | Timeframe dos topos/fundos |
| `InpSwingStrength` | 3 | Candles depois do topo/fundo para confirmar |
| `InpLeftBars` | 12 | O topo/fundo precisa ser o extremo dos N candles anteriores (menor = atualiza mais rápido) |
| `InpMinSwingATR` | 1.5 | Tamanho mínimo do movimento (em ATR) |
| `InpConfirmTF` | M5 | Timeframe do candle de recusa |
| `InpEntriesPerCycle` | 10 | Limite de entradas do ciclo |
| `InpEntryMode` | Uma por recusa | Como abrir as próximas entradas: por recusa, pirâmide (a favor) ou preço médio (contra) |
| `InpOrdersPerRejection` | 1 | Ordens abertas em cada candle de recusa |
| `InpStepPrice` | 1.50 | Pirâmide/preço médio: distância entre ordens (US$) |
| `InpMinSecondsBetween` | 30 | Pirâmide/preço médio: intervalo mínimo entre ordens (segundos) |
| `InpLot` | 0.01 | Lote de cada ordem |
| `InpLotMultiplier` | 1.0 | Multiplicador de lote a cada entrada (acima de 1 = martingale) |
| `InpNewCycleAfterLimit` | não | `false`: o próximo topo/fundo relevante inicia novo ciclo. `true`: espera o atual completar as N entradas |
| `InpMaxOpenCycles` | 3 | Ciclos abertos ao mesmo tempo |
| `InpMaxCycles` | 0 | Parar após X ciclos iniciados (0 = sem limite) |
| `InpCycleLimitScope` | Por dia | Contagem dos ciclos: por dia ou total |
| `InpTPMode` | US$ do preço médio | Tipo de alvo: dinheiro, % topo-fundo, dinheiro ou %, US$ do preço médio |
| `InpTPRangePct` | 30 | Alvo em % da distância entre topo e fundo relevantes |
| `InpTPPriceDist` | 3.0 | Alvo em US$ a favor do preço médio |
| `InpBasketTPMoney` | 5 | **Lucro X para sair**, na moeda da conta. O painel mostra quanto movimento do ouro isso representa |
| `InpTPPerExtraOrder` | 0 | Alvo em dinheiro maior a cada ordem extra |
| `InpServerTP` | sim | Envia o alvo, o stop técnico e o trailing como TP/SL reais nas ordens |
| `InpIncludeCommission` | sim | Desconta comissão (entrada + saída) do lucro da cesta |
| `InpTrailMode` | Desligado | Trailing stop da cesta |
| `InpTrailStartPrice` | 3.0 | Início do trailing (US$ a favor do preço médio) |
| `InpTrailDistPrice` | 1.5 | Recuo do trailing (US$ a partir do melhor preço) |
| `InpTrailLockPct` | 50 | % do lucro garantido quando o trailing ativa |
| `InpInvalidateATR` | 1.0 | Stop técnico além do nível |
| `InpTimeExitMinutes` | 0 | Saída por tempo (0 = desligada) |
| `InpDailyTargetMoney` / `InpDailyMaxLossMoney` | 0 | Meta e perda diária (0 = desligado) |
| `InpEquityTarget` | 0 | Fecha tudo e para quando o equity chegar a X |
| `InpMaxSpreadPrice` | 0.60 | Spread máximo para entrar |
| `InpMagic` | 440030 | Número mágico base. Cada ciclo usa base + 0..9; outra instância no mesmo símbolo deve usar base + 10 ou mais |

**Mudanças em relação às versões anteriores**:
- os modos a favor/contra voltaram como `InpEntryMode` (pirâmide e preço médio), junto com o novo modo "uma por recusa";
- `InpInitialOrders` virou `InpOrdersPerRejection`;
- `InpMaxCycles` agora conta os ciclos **iniciados**;
- o alvo em % é medido **a partir do nível operado**;
- a saída por tempo vem desligada.

Confira os parâmetros salvos no Testador antes de rodar.

**Valores em dinheiro** usam a **moeda da conta**. No Testador de Estratégia o depósito costuma ser em **USD**, então um alvo de 100 significa US$ 100, o que exige um movimento de US$ 100 no ouro com 0.01 lote. Confira no painel a linha "US$ 1 no ouro = ...".

## Recomendações

- Faça **backtest** no Testador de Estratégia com "Cada tick baseado em ticks reais". Depois rode em **demo** antes de usar a conta real.
- Vários ciclos abertos ao mesmo tempo somam exposição. Ajuste `InpMaxOpenCycles`, o lote e o stop técnico ao tamanho da conta.
- `InpLotMultiplier` acima de 1.0 vira martingale. Use com muito cuidado.
- O estado dos ciclos fica salvo em Variáveis Globais do terminal (F3), e cada teste no Testador começa do zero. Para começar do zero na conta, use `InpResetState = true`.

> Aviso: operar ouro alavancado tem alto risco. Este robô não garante lucro.
