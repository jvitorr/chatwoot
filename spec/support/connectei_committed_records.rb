# [FORK CONNECTEI] modifications/026 e 027b — limpeza dos specs de concorrência.
#
# Concorrência de verdade (duas conexões) exige dados COMMITADOS, então esses
# specs desligam a transação do exemplo e precisam limpar o que commitaram — e SÓ
# isso. Apagar a tabela inteira (DatabaseCleaner) remove também o que outros
# arquivos commitam no CARREGAMENTO (o blob do `slack_uploads_controller_spec.rb`
# nasce fora de qualquer exemplo) e quebra esses specs depois; TRUNCATE ainda
# reinicia as sequências, e chaves que o MockRedis guarda por id passam a valer
# para registros novos.
#
# O retrato guarda o maior `id` de cada tabela antes do exemplo; a limpeza apaga
# só as linhas acima dele. Uso:
#
#   self.use_transactional_tests = false
#   around { |example| ConnecteiCommittedRecords.isolate { example.run } }
module ConnecteiCommittedRecords
  module_function

  def isolate
    snapshot = take_snapshot
    yield
  ensure
    cleanup(snapshot) if snapshot
  end

  def take_snapshot
    connection.tables.each_with_object({}) do |table, snapshot|
      next unless integer_id?(table)

      snapshot[table] = connection.select_value("SELECT COALESCE(MAX(id), 0) FROM #{connection.quote_table_name(table)}").to_i
    end
  end

  def cleanup(snapshot)
    connection.disable_referential_integrity do
      snapshot.each do |table, max_id|
        connection.execute("DELETE FROM #{connection.quote_table_name(table)} WHERE id > #{max_id.to_i}")
      end
    end
  end

  def integer_id?(table)
    connection.columns(table).any? { |column| column.name == 'id' && column.type == :integer }
  end

  def connection
    ActiveRecord::Base.connection
  end
end
