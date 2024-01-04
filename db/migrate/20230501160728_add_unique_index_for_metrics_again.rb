class AddUniqueIndexForMetricsAgain < ActiveRecord::Migration[7.1]
  def change
    # Remove duplicate metrics for kind, family_id, date
    Metric.select(:kind, :subkind, :family_id, :date).group(:kind, :subkind, :family_id, :date).having('count(*) > 1').each do |metric|
      metric_ids = Metric.where(kind: metric.kind, subkind: metric.subkind, family_id: metric.family_id, date: metric.date).pluck(:id)
      metric_ids.shift
      Metric.where(id: metric_ids).delete_all
    end

    remove_index :metrics, [:kind, :subkind, :family_id, :date]
    
    add_index :metrics, [:kind, :subkind, :family_id, :date], unique: true, where: 'subkind IS NOT NULL'
    add_index :metrics, [:kind, :family_id, :date], unique: true, where: 'subkind IS NULL'
  end
end