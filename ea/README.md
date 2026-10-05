# K4 XAUUSD — versão Multi (mais operações + grade)

| Arquivo | O que é |
|---|---|
| `K4_XAUUSD.mq5` | Original v3.17, sem alterações (referência). |
| `K4_XAUUSD_Multi.mq5` | Variante com operações simultâneas, filtro de tendência opcional e grade de recuperação. |

## Instalação

Copie `K4_XAUUSD_Multi.mq5` para a **mesma pasta** do `K4_XAUUSD.mq5`, onde estão os
`H4M30_*.mqh` e `K4_*.mqh`, e compile no MetaEditor. A estratégia (níveis H4, stop M30, alvo 3R,
trailing) continua sendo a do `H4M30_Core.mqh`; nada nela foi alterado.

Com `InpMaxTrades=1` e `InpGridEnable=false`, o comportamento é o mesmo do original.

## O que muda

### 1. Operações simultâneas (`InpMaxTrades`)
No original, um sinal que aparece com uma posição já aberta é **consumido e descartado**.
Com `InpMaxTrades>1`, esses sinais passam a ser operados (cada um com stop, alvo e trailing próprios).

### 2. Filtro de tendência opcional (`InpUseTrendFilter`)
`false` aceita também os sinais contra a EMA. Gera mais operações, mas de qualidade menor.
Teste antes de usar em conta real.

### 3. Grade de recuperação (`InpGridEnable`)
Uma **cesta** é o conjunto de ordens do robô numa direção (no máximo uma cesta de compra e uma de venda).

1. O sinal abre a 1ª ordem normalmente. Se o preço for a favor, ela segue como no original (alvo 3R + trailing).
2. Se o preço andar **contra** por uma distância de grade, abre outra ordem na mesma direção.
   A distância é `max(InpGridStepPoints, InpGridStepATR × ATR H1)` e cresce `× InpGridStepExpansion` a cada nível.
3. A partir de 2 ordens, **todas** passam a ter o mesmo alvo: preço médio ± `InpGridTargetPoints`.
   Quando o preço volta ao médio + alvo, a cesta inteira fecha no lucro.
4. **Toda cesta tem stop no servidor.** Com `GRID_STOP_AFTER_LAST`, o stop fica `InpGridStopAfterSteps`
   distâncias após o último nível (nunca mais perto que o stop estrutural original). Com
   `GRID_STOP_STRUCTURE`, ele fica no stop M30 original e a grade só abre ordens dentro dele.
5. **Limite de risco:** antes de cada ordem, o robô soma a perda de todas as ordens se cada uma bater
   no stop. Se passar de `InpGridMaxRiskPct`% do saldo, a ordem não abre. Se a grade completa não couber
   no limite, a entrada usa o stop original e o motivo é registrado na aba Experts.

A grade só abre ordens no mesmo horário de entrada (`InpEntryStartUTC`–`InpEntryEndUTC`), nunca durante o rollover.
Ela exige conta **hedging**; em conta netting o EA recusa iniciar se `InpMaxTrades>1` ou se a grade estiver ligada.

### Parâmetros da grade

| Parâmetro | Padrão | Observação |
|---|---|---|
| `InpMaxTrades` | 2 | Sinais simultâneos. Com grade: 1 cesta por direção (máx. 2). |
| `InpUseTrendFilter` | true | `false` = mais sinais. |
| `InpGridEnable` | true | Liga a grade. |
| `InpGridMaxOrders` | 4 | Ordens por cesta, incluindo a do sinal. |
| `InpGridStepATR` | 1.0 | Distância em ATR(14) H1. 0 = usar só pontos. |
| `InpGridStepPoints` | 500 | Distância mínima (500 pontos = 5.00 USD no ouro). |
| `InpGridStepExpansion` | 1.2 | Cada distância seguinte é 20% maior. |
| `InpGridLotMultiplier` | 1.0 | 1.0 = lote fixo. Acima de 1.0 é martingale: o risco cresce muito rápido. |
| `InpGridMaxLot` | 0.05 | Teto de lote por ordem. |
| `InpGridTargetPoints` | 300 | Alvo da cesta além do preço médio (3.00 USD). |
| `InpGridStop` | Após o último nível | Ou stop estrutural original. |
| `InpGridStopAfterSteps` | 1.0 | Distância do stop após o último nível. |
| `InpGridMaxRiskPct` | 20 | Perda máxima somando todos os stops, em % do saldo. |

### Exemplo de risco (padrões, ATR H1 = 15 USD, lote 0.01)

Níveis a 0, −15, −33 e −54,60 USD da entrada; stop em −80,52 USD.
Se a cesta inteira bater no stop, as 4 ordens perdem 80,52 + 65,52 + 47,52 + 25,92 = 219,48 USD de movimento.
Numa conta padrão (contrato de 100 oz, 0.01 lote = 1 oz), isso é cerca de **219 USD** por cesta perdida.
Numa conta cent, o valor sai em USC; confira a especificação do símbolo na corretora.
O cálculo do robô usa `OrderCalcProfit`, então já considera a moeda da conta.

## Avisos importantes

- **Grade não cria vantagem; ela troca muitas perdas pequenas por poucas perdas grandes.** A taxa de acerto
  sobe e a curva fica mais lisa até um dia de tendência forte, que leva a cesta inteira ao stop.
  No ouro, movimentos de 50 a 100 USD num dia acontecem várias vezes por ano.
- Teste no Strategy Tester com **"Every tick based on real ticks"**, em pelo menos 2 anos, comparando
  com o original. Olhe o **rebaixamento máximo (drawdown)** e a maior perda isolada, não só o lucro.
- O EA verifica `SYMBOL_TRADE_CONTRACT_SIZE == 100`. Se o XAUUSD da conta cent tiver outro tamanho de
  contrato, o EA (original e Multi) não inicia.
- Se a atualização automática (`K4_AutoApply`) substituir este EA pela versão oficial, as ordens abertas
  continuam com stop e alvo no servidor, mas a grade deixa de adicionar níveis.
- Este arquivo não foi compilado aqui, porque os `.mqh` não estavam disponíveis. Compile no MetaEditor
  e teste em conta demo antes de usar com dinheiro real.

## Para operar com mais frequência (próximo passo)

A frequência de **sinais** é definida no `H4M30_Core.mqh`: níveis H4, aproximação de 0,05 ATR e
filtro EMA. Para ter sinal praticamente todo dia, a alteração mais direta é permitir níveis de H1
(ou reentrada no mesmo nível depois de um alvo), e isso precisa ser feito no core.
