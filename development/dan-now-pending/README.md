# Dan NOW: tolerância, pendente de retorno e parâmetros por etapas

Base: pacote oficial 1.7.34, SHA-256 054ba1732fbd25e8c4410dd55a7c7134c02f9e7304dc640a5a6e7b4285a233de.

Código preparado para a próxima versão; não é uma publicação no canal automático.

- NOW do Dan XAUUSD: tolerância própria padrão de 3,00 unidades de preço (300 pontos quando point=0,01). As demais entradas mantêm sua configuração.
- Fora da tolerância, quando o mercado se afastou na direção da operação, cria LIMIT no preço anunciado. Não cria STOP se o preço se afastou no sentido contrário. As validações de preço, SL, TP, spread, margem, risco e duplicidade continuam.
- Os três lotes provisórios NOW são preservados; SL provisório de 12 unidades calculado sobre o preço planejado.
- Parâmetros em mensagens separadas: SL/TP literais de uma sequência recente, sem outro sinal intermediário, podem completar a origem NOW. Registra a mensagem de origem de cada complemento. Uma mensagem TP não autoriza um número arbitrário como SL.
- Um TP comum atualiza as três pernas já alocadas; SL isolado atualiza as ordens existentes.
- Somente novas pendentes criadas por esse fallback recebem a política de cancelamento: primeiro alvo observado antes da entrada ou vencimento. Validade padrão 24 horas. Cancelamento explícito continua no fluxo existente.
- O monitor consulta cotação validada e confirma ticket/conta/magic antes de remover; nunca fecha a posição que já ativou. Decisão de cancelamento persistida em SQLite, inclusive após reinício; envio incerto não é repetido.

Configuração `profiles.dan_golden.execution`:

```json
{
  "now_entry_tolerance_price": 3.0,
  "now_pending_fallback_enabled": true,
  "now_pending_validity_seconds": 86400
}
```

Limites: monitoramento exige aplicativo conectado. Não é OCO nativo na corretora e não reconstrói toques no TP ocorridos durante desconexão ou entre consultas. Sem TP informado, cancela por validade ou cancelamento explícito. Se a cotação mudar entre planejamento e envio, a validação pode bloquear a ordem; não há conversão tardia nem repetição de envio incerto. A validade padrão é uma escolha de implementação, configurável.

Aplicação ao código: extrair o pacote oficial 1.7.34 e aplicar `changes.patch` dentro da pasta `app`. O snapshot de código inclui os arquivos Python da aplicação e testes; não é instalador nem pacote assinado. O número da versão de produção permanece 1.7.34 até empacotar e assinar uma release. Nenhuma assinatura existente foi reaproveitada para código modificado.

Validação: testes unittest com modelo e MT5 simulados; não houve conexão a conta real, chamada real à IA ou envio de ordem real. Resultado final registrado na descrição do PR.
