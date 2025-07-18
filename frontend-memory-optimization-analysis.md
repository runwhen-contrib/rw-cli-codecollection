# Frontend Memory Optimization Analysis

## Problem Statement
The user-pages frontend application is consuming 1-2 GB of RAM for workspaces with many entities and runsessions, particularly on the `/workspace/{workspace_id}/chat` endpoint.

## Common Memory Issues in Frontend Applications

### 1. **Data Caching and State Management**
**Issues:**
- Storing all entities and runsessions in memory simultaneously
- Not implementing proper data pagination
- Keeping unnecessary data in component state
- Memory leaks from unsubscribed observables/event listeners

**Solutions:**
```javascript
// Implement virtual scrolling for large lists
import { FixedSizeList as List } from 'react-window';

// Use pagination with lazy loading
const usePaginatedData = (pageSize = 50) => {
  const [data, setData] = useState([]);
  const [page, setPage] = useState(1);
  const [loading, setLoading] = useState(false);
  
  const loadMore = useCallback(async () => {
    setLoading(true);
    const newData = await fetchData(page, pageSize);
    setData(prev => [...prev, ...newData]);
    setPage(prev => prev + 1);
    setLoading(false);
  }, [page, pageSize]);
  
  return { data, loading, loadMore };
};

// Implement proper cleanup
useEffect(() => {
  const subscription = dataStream.subscribe(handleData);
  return () => subscription.unsubscribe();
}, []);
```

### 2. **Component Memory Leaks**
**Issues:**
- Components not unmounting properly
- Event listeners not being cleaned up
- Timers and intervals persisting
- Large objects in closures

**Solutions:**
```javascript
// Proper cleanup in useEffect
useEffect(() => {
  const timer = setInterval(() => {
    // Update logic
  }, 1000);
  
  return () => {
    clearInterval(timer);
  };
}, []);

// Use AbortController for fetch requests
useEffect(() => {
  const abortController = new AbortController();
  
  fetch(url, { signal: abortController.signal })
    .then(response => response.json())
    .catch(error => {
      if (error.name === 'AbortError') return;
      // Handle other errors
    });
    
  return () => abortController.abort();
}, [url]);
```

### 3. **Large Object References**
**Issues:**
- Storing full entity objects when only IDs are needed
- Deep cloning large objects unnecessarily
- Circular references in data structures

**Solutions:**
```javascript
// Use normalized state structure
const normalizedState = {
  entities: {
    byId: {
      'entity1': { id: 'entity1', name: 'Entity 1', ... },
      'entity2': { id: 'entity2', name: 'Entity 2', ... }
    },
    allIds: ['entity1', 'entity2']
  }
};

// Implement object pooling for frequently created objects
class ObjectPool {
  constructor(createFn, resetFn) {
    this.pool = [];
    this.createFn = createFn;
    this.resetFn = resetFn;
  }
  
  get() {
    return this.pool.pop() || this.createFn();
  }
  
  release(obj) {
    this.resetFn(obj);
    this.pool.push(obj);
  }
}
```

### 4. **Rendering Optimization**
**Issues:**
- Unnecessary re-renders of large component trees
- Not using React.memo, useMemo, or useCallback
- Rendering all items in a list instead of visible ones

**Solutions:**
```javascript
// Use React.memo for expensive components
const ExpensiveComponent = React.memo(({ data }) => {
  return <div>{/* Expensive rendering logic */}</div>;
});

// Use useMemo for expensive calculations
const expensiveValue = useMemo(() => {
  return data.reduce((acc, item) => acc + item.value, 0);
}, [data]);

// Use useCallback for function props
const handleItemClick = useCallback((id) => {
  // Handle click
}, []);
```

### 5. **Bundle Size and Code Splitting**
**Issues:**
- Loading all code upfront
- Large third-party dependencies
- Unused code in production

**Solutions:**
```javascript
// Implement code splitting
const ChatComponent = lazy(() => import('./ChatComponent'));
const EntityList = lazy(() => import('./EntityList'));

// Use dynamic imports for heavy libraries
const loadHeavyLibrary = async () => {
  const { default: HeavyLibrary } = await import('heavy-library');
  return HeavyLibrary;
};
```

## Specific Recommendations for Chat Endpoint

### 1. **Implement Virtual Scrolling for Chat Messages**
```javascript
import { FixedSizeList as List } from 'react-window';

const ChatMessageList = ({ messages }) => {
  const Row = ({ index, style }) => (
    <div style={style}>
      <ChatMessage message={messages[index]} />
    </div>
  );
  
  return (
    <List
      height={600}
      itemCount={messages.length}
      itemSize={80}
      width="100%"
    >
      {Row}
    </List>
  );
};
```

### 2. **Implement Message Pagination**
```javascript
const useChatMessages = (workspaceId) => {
  const [messages, setMessages] = useState([]);
  const [hasMore, setHasMore] = useState(true);
  const [page, setPage] = useState(1);
  
  const loadMessages = useCallback(async () => {
    const response = await fetch(
      `/api/workspace/${workspaceId}/chat/messages?page=${page}&limit=50`
    );
    const newMessages = await response.json();
    
    setMessages(prev => [...prev, ...newMessages]);
    setHasMore(newMessages.length === 50);
    setPage(prev => prev + 1);
  }, [workspaceId, page]);
  
  return { messages, hasMore, loadMessages };
};
```

### 3. **Optimize Entity and RunSession Data**
```javascript
// Only load essential data initially
const useWorkspaceData = (workspaceId) => {
  const [entities, setEntities] = useState([]);
  const [runSessions, setRunSessions] = useState([]);
  
  // Load summary data first
  const loadSummary = useCallback(async () => {
    const response = await fetch(`/api/workspace/${workspaceId}/summary`);
    const summary = await response.json();
    setEntities(summary.entities.map(e => ({ id: e.id, name: e.name })));
    setRunSessions(summary.runSessions.map(r => ({ id: r.id, status: r.status })));
  }, [workspaceId]);
  
  // Load full data on demand
  const loadFullEntity = useCallback(async (entityId) => {
    const response = await fetch(`/api/entity/${entityId}`);
    return response.json();
  }, []);
  
  return { entities, runSessions, loadSummary, loadFullEntity };
};
```

### 4. **Implement Memory Monitoring**
```javascript
const useMemoryMonitor = () => {
  useEffect(() => {
    const checkMemory = () => {
      if ('memory' in performance) {
        const { usedJSHeapSize, totalJSHeapSize } = performance.memory;
        const usageMB = usedJSHeapSize / 1024 / 1024;
        
        if (usageMB > 1000) { // 1GB threshold
          console.warn('High memory usage detected:', usageMB, 'MB');
          // Implement cleanup strategies
        }
      }
    };
    
    const interval = setInterval(checkMemory, 30000); // Check every 30 seconds
    return () => clearInterval(interval);
  }, []);
};
```

## Performance Monitoring Tools

### 1. **Chrome DevTools Memory Profiler**
- Use the Memory tab to identify memory leaks
- Take heap snapshots to analyze object retention
- Monitor memory usage over time

### 2. **React DevTools Profiler**
- Profile component render times
- Identify unnecessary re-renders
- Analyze component tree performance

### 3. **Web Vitals Monitoring**
```javascript
import { getCLS, getFID, getFCP, getLCP, getTTFB } from 'web-vitals';

function sendToAnalytics(metric) {
  // Send metrics to your analytics service
  console.log(metric);
}

getCLS(sendToAnalytics);
getFID(sendToAnalytics);
getFCP(sendToAnalytics);
getLCP(sendToAnalytics);
getTTFB(sendToAnalytics);
```

## Implementation Priority

1. **High Priority:**
   - Implement virtual scrolling for large lists
   - Add proper cleanup in useEffect hooks
   - Implement pagination for chat messages and entities

2. **Medium Priority:**
   - Optimize component rendering with React.memo
   - Implement code splitting for heavy components
   - Add memory monitoring and alerts

3. **Low Priority:**
   - Optimize bundle size
   - Implement object pooling
   - Add advanced caching strategies

## Expected Results

After implementing these optimizations, you should see:
- 50-70% reduction in memory usage
- Improved page load times
- Better user experience with large datasets
- Reduced server load from client-side caching

## Next Steps

1. Profile the current application using Chrome DevTools
2. Identify the specific components causing memory issues
3. Implement virtual scrolling for the chat interface
4. Add pagination to entity and runsession lists
5. Monitor memory usage after each optimization
6. Implement memory monitoring in production