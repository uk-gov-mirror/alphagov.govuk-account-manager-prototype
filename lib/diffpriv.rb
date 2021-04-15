class Diffpriv
  FIELDNAMES_TO_SCREEN_AS_PRIVATE =  %w[id, email, name, phone]
  MODELS_TO_EXPORT = %w[User]

  def self.dump_schema
    {
      Rails.configuration.database_configuration["development"]["database"] => export_tables
    }
  end

  def self.export_tables
    Rails.application.eager_load!
    models = ActiveRecord::Base.descendants.select { |model_name| MODELS_TO_EXPORT.include?(model_name.name) }
    models.each_with_object({}) do |model, model_hash|
      model_hash[model.name] = {
        rows: model.count,
        **table_attributes(model),
      }
    end
  end

  def self.table_attributes(model)
    model.attribute_types.each_with_object({}) do |attribute_pair, hash|
      hash[attribute_pair.first.to_sym] = {
        type: attribute_pair.second.type.to_s,
        **conditionally_add_actual_minmax(attribute_pair, model)
      }
    end
  end

  def self.conditionally_add_table_minmax(attribute_value)
    if attribute_value.type == :integer
      {
        upper: attribute_value.range.max,
        lower: attribute_value.range.min
      }
    else
      {}
    end
  end

  def self.conditionally_add_actual_minmax(attribute_pair, model)
    if attribute_pair.second.type == :integer
      {
        upper: establish_actual_maxmimum(model.maximum(attribute_pair.first.to_sym)),
        lower: establish_actual_minimum(model.minimum(attribute_pair.first.to_sym))
      }
    else
      {}
    end
  end

  def self.establish_actual_maxmimum(value)
    return 0 if value == 0 || value.nil?
    value.round(1) * 100 if value > 0
  end

  def self.establish_actual_minimum(value)
    return 0 if value == 0 || value.nil?
    return value.round(1) * 100 if value < 0
    1
  end

end
