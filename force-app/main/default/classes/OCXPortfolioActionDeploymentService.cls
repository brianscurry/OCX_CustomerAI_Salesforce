public without sharing class OCXPortfolioActionDeploymentService {
    public class ActionItem {
        public String title;
        public String description;
        public String dueDate;
        public String priority;
        public Integer sequence;
    }

    public class CtaItem {
        public String title;
        public String description;
        public String dueDate;
        public String priority;
        public Integer sequence;
        public List<ActionItem> tasks = new List<ActionItem>();
    }

    public static List<CtaItem> parseCtas(String markdown) {
        List<CtaItem> result = new List<CtaItem>();
        if (String.isBlank(markdown)) {
            return result;
        }

        Integer marker = markdown.indexOf('```ocx-actions');
        if (marker < 0) {
            return result;
        }

        Integer jsonStart = markdown.indexOf('\n', marker);
        if (jsonStart < 0) {
            return result;
        }

        Integer jsonEnd = markdown.indexOf('```', jsonStart + 1);
        if (jsonEnd < 0) {
            return result;
        }

        String jsonText = markdown.substring(jsonStart + 1, jsonEnd).trim();
        if (String.isBlank(jsonText)) {
            return result;
        }

        Object parsed = JSON.deserializeUntyped(jsonText);
        if (!(parsed instanceof List<Object>)) {
            return result;
        }

        for (Object raw : (List<Object>) parsed) {
            if (!(raw instanceof Map<String, Object>)) {
                continue;
            }

            Map<String, Object> row = (Map<String, Object>) raw;
            if (!'CTA'.equalsIgnoreCase(text(row.get('actionType')))) {
                continue;
            }

            CtaItem cta = new CtaItem();
            cta.title = text(row.get('title'));
            cta.description = text(row.get('description'));
            cta.dueDate = text(row.get('dueDate'));
            cta.priority = text(row.get('priority'));
            cta.sequence = integerValue(row.get('sequence'));

            Object nested = row.get('tasks');
            if (nested instanceof List<Object>) {
                for (Object childRaw : (List<Object>) nested) {
                    if (!(childRaw instanceof Map<String, Object>)) {
                        continue;
                    }
                    Map<String, Object> child = (Map<String, Object>) childRaw;
                    ActionItem item = new ActionItem();
                    item.title = text(child.get('title'));
                    item.description = text(child.get('description'));
                    item.dueDate = text(child.get('dueDate'));
                    item.priority = text(child.get('priority'));
                    item.sequence = integerValue(child.get('sequence'));
                    cta.tasks.add(item);
                }
            }
            result.add(cta);
        }
        return result;
    }

    public static String buildDescription(CtaItem cta, String portfolioName) {
        List<String> sections = new List<String>();
        if (String.isNotBlank(cta.description)) {
            sections.add(cta.description.trim());
        }

        if (cta.tasks != null && !cta.tasks.isEmpty()) {
            List<String> lines = new List<String>();
            Integer position = 0;
            for (ActionItem item : cta.tasks) {
                position++;
                String line = String.valueOf(position) + '. ' +
                    (String.isBlank(item.title) ? 'Untitled task' : item.title.trim());
                if (String.isNotBlank(item.description)) {
                    line += '\n   ' + item.description.trim()
                        .replace('\r\n', '\n')
                        .replace('\r', '\n')
                        .replace('\n', '\n   ');
                }
                lines.add(line);
            }
            sections.add('Tasks\n\n' + String.join(lines, '\n\n'));
        }

        sections.add(
            'Source Portfolio: ' + portfolioName + '\n' +
            'Open the published Portfolio action-plan workbook for the full analysis and working materials.'
        );

        String value = String.join(sections, '\n\n');
        return value.length() > 32000 ? value.substring(0, 32000) : value;
    }

    public static String hash(String value) {
        Blob digest = Crypto.generateDigest('SHA-256', Blob.valueOf(value));
        return EncodingUtil.convertToHex(digest);
    }

    private static String text(Object value) {
        return value == null ? null : String.valueOf(value);
    }

    private static Integer integerValue(Object value) {
        if (value == null) {
            return null;
        }
        Decimal decimalValue = Decimal.valueOf(String.valueOf(value));
        return decimalValue.intValue();
    }
}