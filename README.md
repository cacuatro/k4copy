# NewsRider EA (MT4)

Robô de notícias para MetaTrader 4. Ele entra **a favor do movimento da notícia** e protege o lucro com **breakeven + trailing rápido**.

Ele não precisa da `libNewsFF.ex4`: o calendário do ForexFactory é baixado e lido pelo próprio EA.

Arquivo: [`MQL4/Experts/NewsRider_EA.mq4`](MQL4/Experts/NewsRider_EA.mq4)

## Instalação

1. No MT4, abra **Arquivo → Abrir Pasta de Dados → MQL4 → Experts** e copie o `NewsRider_EA.mq4` para lá.
2. Abra o arquivo no MetaEditor e aperte **F7** para compilar.
3. Para conta demo ou real, abra **Ferramentas → Opções → Expert Advisors**, marque **"Permitir WebRequest para as URLs listadas"** e adicione:
   ```
   https://nfs.faireconomy.media
   ```
4. Arraste o EA para o gráfico (por exemplo, XAUUSD M1 ou M5) e ligue a **Negociação Automatizada**.

O painel no canto do gráfico mostra a próxima notícia, o fuso do servidor e o status.

## Como ele opera

| Modo | O que faz |
|---|---|
| **Straddle** (padrão) | `InpSecondsBefore` segundos antes da notícia, coloca um **Buy Stop** e um **Sell Stop** a `InpEntryDistance` pontos do preço. Quando uma executa, a outra é apagada. Se nenhuma executar, as duas são apagadas `InpPendingExpireSec` segundos depois da notícia. |
| **Momentum** | Guarda o preço logo antes da notícia. Se, dentro de `InpMomentumWindow` segundos, o preço andar `InpMomentumTrigger` pontos para um lado, abre a mercado nessa direção. Não sofre com o spread abrindo pendentes. |

Gestão da posição, a cada tick:

- **Breakeven**: com `InpBETrigger` pontos de lucro, move o stop para a entrada + `InpBELock`.
- **Trailing**: com `InpTrailStart` pontos de lucro, o stop segue o preço a `InpTrailDistance` pontos e anda de `InpTrailStep` em `InpTrailStep`.
- **Tempo máximo**: fecha depois de `InpMaxTradeMinutes` minutos.
- O padrão é **sem take profit** (`InpTakeProfit = 0`): quem fecha a operação é o trailing.

Filtros de notícia:

- **Moedas**: vazio = automático pelo símbolo (XAUUSD → USD).
- **Impacto mínimo**: padrão "somente alto".
- **Palavras para incluir ou excluir** no título. Por padrão ignora discursos (`Speaks;Testifies`), que não têm horário exato.
- Exemplo para operar só payroll, CPI e juros:
  `InpTitleInclude = Non-Farm;CPI;Federal Funds Rate`

### Sobre os pontos

Tudo é em **pontos** do MT4. No XAUUSD com 2 casas decimais (ex: 2650.35), **100 pontos = 1,00 dólar no preço**. Os valores padrão (entrada a 150, SL 300, trailing 100) foram pensados para o ouro. Se o seu XAUUSD tiver 3 casas decimais, multiplique tudo por 10.

## Backtest

O feed do ForexFactory só tem a **semana atual**, e o `WebRequest` não funciona no Testador de Estratégia. Por isso, no backtest o EA usa uma destas fontes:

1. **Arquivo de histórico** `NewsHistory.csv`, na pasta `Common\Files` do MetaTrader. Para abrir essa pasta: Arquivo → Abrir Pasta de Dados, suba dois níveis e entre em `Common\Files`.
   - Quando o EA roda em demo ou real, ele **salva automaticamente** neste arquivo todas as notícias que baixa. Com o tempo, você acumula histórico para testar.
   - Você também pode preencher o arquivo à mão. O formato tem uma linha por notícia, **horário em UTC**, separado por `;`:
     ```
     # data_hora_utc;moeda;impacto;titulo
     2026.10.03 12:30;USD;High;Non-Farm Employment Change
     2026.10.15 12:30;USD;High;CPI m/m
     ```
     (essas duas linhas são só exemplo de formato)
2. **Horários manuais** (`InpManualTimes`), no **horário do gráfico**, separados por `;`.
   Exemplo: `2026.10.03 15:30;2026.10.15 15:30`.
   Em servidores GMT+2/GMT+3, como normalmente é o da RoboForex, dados dos EUA divulgados às 8:30 de Nova York aparecem às **15:30 no gráfico**. Dá para achar os candles de notícia direto no gráfico.

Para o backtest:

- Use o modelo **"Todos os ticks"**. Os outros modelos não simulam o movimento dentro do candle.
- Mantenha `InpSecondsBefore` em **60 ou mais**. O testador do MT4 trabalha com candles de 1 minuto e não simula os segundos dentro do candle.
- Corrija o histórico do símbolo (F2 → Centro de Históricos → baixar M1) para evitar os erros `TestGenerator: unmatched data error`.
- O testador do MT4 não reproduz o spread real nem o slippage de notícia. O resultado real costuma ser **pior** que o do backtest. Teste em conta **demo** antes de usar dinheiro real.

### Fuso do servidor

Com `InpServerGMTOffset = 99` (automático):

- Em demo ou real, o EA mede o fuso comparando o horário do servidor com o do computador.
- No backtest, usa o padrão das corretoras "NY close", como a RoboForex: GMT+3 durante o horário de verão dos EUA e GMT+2 no resto do ano.

Se as notícias não baterem com os candles, coloque o fuso manualmente (por exemplo, `3`).

## Riscos de operar notícia

- No momento da notícia o **spread abre muito** e pode haver **slippage** grande. Pendentes podem executar longe do preço, e o stop pode não sair no preço exato.
- No modo Straddle, se o preço for e voltar rápido (*whipsaw*), a entrada pode acontecer e tomar o stop logo em seguida.
- Algumas corretoras restringem operações perto de notícias. Confira as regras da sua conta.
