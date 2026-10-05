# K4 Rejection Cycles (XAUUSD / MetaTrader 5)

Robô (Expert Advisor) que opera ciclos de entradas no **XAUUSD** na **recusa de topos/fundos relevantes**, pensado para **conta cent**.

## Como funciona

1. **Topo/fundo relevante** (padrão M30): o robô usa o topo e o fundo **mais recentes** que atendem a todas estas condições:
   - é a máxima (ou mínima) mais extrema dos **12 candles anteriores**;
   - tem pelo menos **3 candles depois** confirmando;
   - **nenhum candle depois dele o superou**;
   - o movimento até ele, ou a partir dele, tem pelo menos 1,5×ATR.

   Assim, em tendência de alta o fundo acompanha os **fundos mais altos** dos recuos, e em tendência de baixa o topo acompanha os **topos mais baixos**. Eles aparecem no gráfico como linhas tracejadas.
2. **Recusa** (padrão M5): um candle fechado que toca a zona do nível, não rompe mais que 0,5×ATR, fecha de volta do lado certo, tem cor a favor e pavio de pelo menos 40% do tamanho.
   - Recusa no topo → **VENDA**. Recusa no fundo → **COMPRA**.
3. **Ciclo de entradas**: com a recusa, o ciclo começa e abre as ordens iniciais. As próximas ordens entram conforme o modo escolhido:
   - `Contra o preço`: a cada US$ 1,50 contra (preço médio).
   - `A favor do preço`: a cada US$ 1,50 a favor (pirâmide).
   - `Por tempo`: a cada X segundos, enquanto o preço segue do lado certo do nível.
4. **Saída rápida**: a cesta inteira fecha no alvo escolhido em `InpTPMode`:
   - `Valor em dinheiro (X)`: quando o lucro somado chega a `InpBasketTPMoney` (+ `InpTPPerExtraOrder` por ordem extra).
   - `% da distância topo-fundo`: o alvo é um preço. A partir da 1ª ordem da cesta, o preço precisa andar `InpTPRangePct`% da distância entre o topo e o fundo relevantes. Exemplo: topo 2.650 e fundo 2.630 (distância US$ 20), alvo 30% → US$ 6. Vendeu em 2.648, então o alvo é 2.642. No preço médio, as ordens extras entram mais acima, então todas lucram mais no mesmo alvo. O alvo aparece como linha verde pontilhada.
   - `O que vier primeiro`: usa os dois alvos.

   A cesta também pode sair:
   - por tempo, no zero a zero, depois de X minutos;
   - pelo stop técnico, se o preço passar 1×ATR além do nível;
   - pelo stop em dinheiro da cesta.
5. **Ciclos**: cada ciclo tem até **10 entradas**. Se a cesta fecha no lucro antes das 10 entradas, o robô pode entrar de novo no mesmo nível com uma nova recusa. Depois de completar as 10 entradas, ou se o nível for rompido, aquele topo/fundo fica marcado como usado. O próximo ciclo só começa no **próximo topo/fundo relevante**.
6. **Limite de ciclos**: `InpMaxCycles` faz o robô parar depois de X ciclos concluídos. A contagem pode ser **por dia** (zera todo dia) ou **total** (zera com `InpResetState = true`). Um ciclo em andamento sempre termina normalmente.

## Instalação

1. No MT5: **Arquivo → Abrir pasta de dados**.
2. Copie `K4_RejectionCycles.mq5` para `MQL5/Experts/`.
3. Abra no MetaEditor e compile (F7).
4. Arraste o robô para um gráfico do XAUUSD (qualquer timeframe) e ative o **Algo Trading**.

> A conta deve ser **hedge**. Em conta netting, as ordens se juntam numa posição só.

## Parâmetros principais

| Parâmetro | Padrão | Significado |
|---|---|---|
| `InpSwingTF` | M30 | Timeframe dos topos/fundos |
| `InpSwingStrength` | 3 | Candles depois do topo/fundo para confirmar |
| `InpLeftBars` | 12 | O topo/fundo precisa ser o extremo dos N candles anteriores (menor = atualiza mais rápido) |
| `InpMinSwingATR` | 1.5 | Tamanho mínimo do movimento (em ATR) |
| `InpConfirmTF` | M5 | Timeframe do candle de recusa |
| `InpEntriesPerCycle` | 10 | Entradas por ciclo |
| `InpLot` | 0.01 | Lote de cada ordem |
| `InpGridMode` | Contra | Como adicionar as próximas ordens |
| `InpStepPrice` | 1.50 | Distância entre ordens (US$ no preço do ouro) |
| `InpTPMode` | Dinheiro | Tipo de alvo: dinheiro, % topo-fundo, ou o que vier primeiro |
| `InpTPRangePct` | 30 | Alvo em % da distância entre topo e fundo relevantes |
| `InpBasketTPMoney` | 100 | **Lucro X para sair** (na moeda da conta; em cent, 100 = US$ 1) |
| `InpTPPerExtraOrder` | 0 | Alvo em dinheiro maior a cada ordem extra (preço médio) |
| `InpInvalidateATR` | 1.0 | Stop técnico além do nível |
| `InpTimeExitMinutes` | 60 | Saída por tempo |
| `InpMaxCycles` | 0 | Parar após X ciclos (0 = sem limite) |
| `InpCycleLimitScope` | Por dia | Contagem dos ciclos: por dia ou total |
| `InpDailyTargetMoney` / `InpDailyMaxLossMoney` | 0 | Meta e perda diária (0 = desligado) |
| `InpEquityTarget` | 0 | Fecha tudo e para quando o equity chegar a X |
| `InpMaxSpreadPrice` | 0.60 | Spread máximo para entrar |

Os valores em dinheiro usam a **moeda da conta**. Na conta cent (USC), 100 = US$ 1,00.

## Recomendações

- Faça **backtest** no Testador de Estratégia com "Cada tick baseado em ticks reais". Depois rode em **demo** antes de usar a conta real.
- O modo `Contra o preço` aumenta a exposição quando o mercado vai contra. Mantenha o **stop técnico** ligado e, se quiser, o `InpBasketSLMoney` e a perda diária.
- `InpLotMultiplier` acima de 1.0 vira martingale. Use com muito cuidado.
- O estado do ciclo fica salvo em Variáveis Globais do terminal (F3). Para começar do zero, use `InpResetState = true`.

> Aviso: operar ouro alavancado tem alto risco. Este robô não garante lucro.
