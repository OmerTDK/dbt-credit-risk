{% macro _add_months(col, n) %}
    {% if target.type == 'bigquery' %}DATE_ADD({{ col }}, INTERVAL {{ n }} MONTH)
    {% else %}{{ col }} + interval ({{ n }}) month{% endif %}
{% endmacro %}
