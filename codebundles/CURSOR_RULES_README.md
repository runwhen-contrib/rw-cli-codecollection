# Cursor Rules for Codebundles

This directory contains cursor rules that help maintain consistency and quality across all RunWhen codebundles. These rules are designed to be used with Cursor IDE to provide intelligent code assistance and ensure best practices.

## Cursor Rules Structure

### Directory-Level Rules
- **`.cursorrules`**: General rules for the entire codebundles directory
- **`.cursorrules-template`**: Template for creating platform-specific rules

### Codebundle-Specific Rules
- **`[codebundle]/.cursorrules`**: Specific rules for individual codebundles
- **`[codebundle]/.cursorrules-[platform]`**: Platform-specific rules for codebundles

## How Cursor Rules Work

Cursor rules are configuration files that tell Cursor IDE how to assist with code development. They can:

1. **Provide Context**: Give Cursor information about the codebase structure and patterns
2. **Enforce Standards**: Ensure consistent coding practices across the project
3. **Improve Suggestions**: Help Cursor provide more relevant code suggestions
4. **Maintain Quality**: Guide developers to follow established best practices

## Using These Cursor Rules

### For New Codebundles

1. **Copy the Template**: Use `.cursorrules-template` as a starting point
2. **Customize for Platform**: Adapt the template for your specific platform (Azure, AWS, GCP, Kubernetes, etc.)
3. **Add Codebundle-Specific Rules**: Create a `.cursorrules` file in your codebundle directory
4. **Follow General Standards**: Ensure your codebundle follows the patterns in the main `.cursorrules`

### For Existing Codebundles

1. **Review Current Patterns**: Analyze existing code to understand current patterns
2. **Create Platform Rules**: Add platform-specific rules if they don't exist
3. **Update Codebundle Rules**: Enhance existing rules based on the standards defined here
4. **Validate Compliance**: Ensure the codebundle follows all applicable rules

## Key Standards Enforced

### Issue Reporting
- **Clear Titles**: Must include entity name, resource type, and scope
- **Structured Details**: Must provide context, metrics, and actionable next steps
- **Consistent Severity**: Use 1-4 scale with clear definitions
- **Portal Links**: Include direct links to cloud provider portals

### Script Development
- **Error Handling**: Comprehensive validation and error handling
- **Output Format**: Both human-readable and machine-readable outputs
- **Documentation**: Clear comments and usage examples
- **Testing**: Syntax validation and integration testing

### Robot Framework
- **Task Naming**: Consistent patterns for task names
- **Documentation**: Proper docstrings and tags
- **Variable Management**: Proper import and validation of variables
- **Issue Integration**: Proper integration with RunWhen issue reporting

## Platform-Specific Considerations

### Azure Codebundles
- Use Azure CLI with proper authentication
- Include resource group and subscription context
- Follow Azure naming conventions
- Use Azure Monitor APIs for metrics

### Kubernetes Codebundles
- Use kubectl for cluster operations
- Include namespace and cluster context
- Follow Kubernetes naming conventions
- Use Kubernetes APIs for resource monitoring

### AWS Codebundles
- Use AWS CLI for resource management
- Include region and account context
- Follow AWS naming conventions
- Use CloudWatch APIs for metrics

### GCP Codebundles
- Use gcloud for resource management
- Include project and region context
- Follow GCP naming conventions
- Use Cloud Monitoring APIs for metrics

## Best Practices for Cursor Rules

### Writing Effective Rules
1. **Be Specific**: Provide clear, actionable guidance
2. **Include Examples**: Show real-world examples of good practices
3. **Consider Context**: Account for platform-specific requirements
4. **Maintain Consistency**: Ensure rules align with overall standards

### Updating Rules
1. **Review Regularly**: Periodically review and update rules
2. **Gather Feedback**: Collect feedback from developers using the rules
3. **Evolve with Standards**: Update rules as coding standards evolve
4. **Document Changes**: Keep track of rule changes and their rationale

### Testing Rules
1. **Validate Syntax**: Ensure cursor rules are properly formatted
2. **Test with Cursor**: Verify that Cursor IDE recognizes and applies the rules
3. **Review Suggestions**: Check that Cursor provides appropriate suggestions
4. **Iterate**: Refine rules based on actual usage and feedback

## Integration with Development Workflow

### Code Review
- Use cursor rules as a checklist during code reviews
- Ensure new code follows established patterns
- Validate issue reporting meets standards
- Check that documentation is comprehensive

### Quality Assurance
- Validate scripts pass syntax checks
- Ensure proper error handling is implemented
- Verify output formats are consistent
- Test with real resources when possible

### Documentation
- Keep cursor rules up to date with codebase changes
- Document new patterns and standards
- Provide examples of good implementations
- Include troubleshooting guidance

## Troubleshooting

### Common Issues
1. **Cursor Not Recognizing Rules**: Ensure `.cursorrules` files are in the correct location
2. **Conflicting Rules**: Resolve conflicts between general and specific rules
3. **Outdated Rules**: Update rules to match current codebase patterns
4. **Missing Context**: Add platform-specific context where needed

### Getting Help
1. **Review Examples**: Look at existing codebundles for examples
2. **Check Documentation**: Review README files for guidance
3. **Ask Questions**: Reach out to the team for clarification
4. **Propose Improvements**: Suggest enhancements to the rules

## Contributing to Cursor Rules

### Adding New Rules
1. **Identify Need**: Determine what new rules would be helpful
2. **Research Patterns**: Study existing code to understand patterns
3. **Write Rules**: Create clear, specific rules with examples
4. **Test Rules**: Verify rules work as expected with Cursor IDE
5. **Document Changes**: Update documentation to reflect new rules

### Improving Existing Rules
1. **Identify Issues**: Find areas where rules could be clearer or more helpful
2. **Propose Changes**: Suggest specific improvements
3. **Test Changes**: Verify improvements work as expected
4. **Update Documentation**: Keep documentation current with rule changes

## Conclusion

These cursor rules are designed to help maintain high-quality, consistent code across all RunWhen codebundles. By following these standards, developers can:

- Create more reliable and maintainable code
- Ensure consistent user experience across codebundles
- Reduce errors and improve debugging capabilities
- Provide better support for LLM-assisted development

Remember that these rules are living documents that should evolve with the codebase and development practices. Regular review and updates ensure they remain relevant and helpful. 