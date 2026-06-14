{% macro _generate_series(start, end) %}
    {% if target.type == 'bigquery' %}SELECT number AS months_on_book FROM UNNEST(GENERATE_ARRAY({{ start }}, {{ end }})) AS number
    {% else %}SELECT unnest(range({{ start }}, {{ end + 1 }})) AS months_on_book{% endif %}
{% endmacro %}
